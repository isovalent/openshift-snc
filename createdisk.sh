#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

source tools.sh
source createdisk-library.sh

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"

INSTALL_DIR=${1:-crc-tmp-install-data}

# If the user set OKD_VERSION in the environment, then use it to set BASE_OS
OKD_VERSION=${OKD_VERSION:-none}
if [[ ${OKD_VERSION} != "none" ]]
then
    BASE_OS=fedora-coreos
    destDirPrefix="crc_okd"
fi
BASE_OS=${BASE_OS:-rhcos}
OPENSHIFT_VERSION=$(${JQ} -r .clusterInfo.openshiftVersion $INSTALL_DIR/crc-bundle-info.json)
BASE_DOMAIN=$(${JQ} -r .clusterInfo.baseDomain $INSTALL_DIR/crc-bundle-info.json)
BUNDLE_TYPE=$(${JQ} -r .type $INSTALL_DIR/crc-bundle-info.json)
destDirPrefix="crc"
if [ ${BUNDLE_TYPE} == "microshift" ]; then
    destDirPrefix="crc_${BUNDLE_TYPE}"
    BASE_OS=rhel
fi

# SNC_PRODUCT_NAME: If user want to use other than default product name (crc)
# VM_PREFIX: short VM name (set by SNC_PRODUCT_NAME) + random string generated by openshift-installer
SNC_PRODUCT_NAME=${SNC_PRODUCT_NAME:-crc}
if [ ${BUNDLE_TYPE} == "microshift" ]; then
    VM_NAME=${SNC_PRODUCT_NAME}
else
    VM_PREFIX=$(get_vm_prefix ${SNC_PRODUCT_NAME})
    VM_NAME="${VM_PREFIX}-master-0"
fi

VM_IP=$(sudo virsh domifaddr ${VM_NAME} | tail -2 | head -1 | awk '{print $4}' | cut -d/ -f1)

wait_for_ssh ${VM_NAME} ${VM_IP}

if [ ${BUNDLE_TYPE} != "microshift" ]; then
    # Remove unused images from container storage
    ${SSH} core@${VM_IP} -- 'sudo crictl rmi --prune'
    
    # Disable kubelet service
    ${SSH} core@${VM_IP} -- sudo systemctl disable kubelet
    
    # Stop the kubelet service so it will not reprovision the pods
    ${SSH} core@${VM_IP} -- sudo systemctl stop kubelet
fi

# Enable the system and user level  podman.socket service for API V2
${SSH} core@${VM_IP} -- sudo systemctl enable podman.socket
${SSH} core@${VM_IP} -- systemctl --user enable podman.socket

if [ ${BUNDLE_TYPE} == "microshift" ]; then
    # Pull openshift release images because as part of microshift bundle creation we
    # don't run microshift service which fetch these image but instead service is run
    # as part of crc so user have a fresh cluster instead something already provisioned
    # but images we cache it as part of bundle.
    ${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
     jq --raw-output '.images | to_entries | map(.value) | join("\n")' /usr/share/microshift/release/release-$(uname -i).json | xargs -n1 podman pull --authfile /etc/crio/openshift-pull-secret
EOF
    # Disable firewalld otherwise generated bundle have it running and each podman container
    # which try to expose a port need to added to firewalld rule manually
    # also in case of microshift the ports like 2222, 443, 80 ..etc need to be manually added
    # and OCP/OKD/podman bundles have it disabled by default.
    ${SSH} core@${VM_IP} -- sudo systemctl disable firewalld
    # Copy the sample microshift config and update the base domain with crc base domain
    ${SSH} core@${VM_IP} -- sudo cp /etc/microshift/config.yaml.default /etc/microshift/config.yaml
    ${SSH} core@${VM_IP} -- "sudo sed -i 's/#baseDomain: .*/baseDomain: ${SNC_PRODUCT_NAME}.${BASE_DOMAIN}/g' /etc/microshift/config.yaml"
fi

remove_pull_secret_from_disk

if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    prepare_hyperV ${VM_IP}
fi

prepare_qemu_guest_agent ${VM_IP}

image_tag="latest"
if podman manifest inspect quay.io/crcont/dnsmasq:${OPENSHIFT_VERSION} >/dev/null 2>&1; then
    image_tag=${OPENSHIFT_VERSION}
fi

# Add gvisor-tap-vsock and crc-dnsmasq services
${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
  podman create --name=gvisor-tap-vsock --privileged --net=host -v /etc/resolv.conf:/etc/resolv.conf -it quay.io/crcont/gvisor-tap-vsock:latest
  podman generate systemd --restart-policy=no gvisor-tap-vsock > /etc/systemd/system/gvisor-tap-vsock.service
  touch /var/srv/dnsmasq.conf
  podman create --ip 10.88.0.8 --name crc-dnsmasq -v /var/srv/dnsmasq.conf:/etc/dnsmasq.conf -p 53:53/udp --privileged quay.io/crcont/dnsmasq:${image_tag}
  podman generate systemd --restart-policy=no crc-dnsmasq > /etc/systemd/system/crc-dnsmasq.service
  systemctl daemon-reload
  systemctl enable gvisor-tap-vsock.service
EOF

# Add dummy crio-wipe service to instance
cat crio-wipe.service | ${SSH} core@${VM_IP} "sudo tee -a /etc/systemd/system/crio-wipe.service"

# Preload routes controller
${SSH} core@${VM_IP} -- "sudo podman pull quay.io/crcont/routes-controller:${image_tag}"

if [ "${ARCH}" == "aarch64" ] && [ ${BUNDLE_TYPE} != "okd" ]; then
   # aarch64 support is mainly used on Apple M1 machines which can't run a rhel8 kernel
   # https://access.redhat.com/solutions/6545411
   install_rhel9_kernel ${VM_IP}
fi

cleanup_vm_image ${VM_NAME} ${VM_IP}

# Only used for macOS bundle generation
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    # Get the rhcos ostree Hash ID
    ostree_hash=$(${SSH} core@${VM_IP} -- "cat /proc/cmdline | grep -oP \"(?<=${BASE_OS}-).*(?=/vmlinuz)\"")

    # Get the rhcos kernel release
    kernel_release=$(${SSH} core@${VM_IP} -- 'uname -r')

    # Get the kernel command line arguments
    kernel_cmd_line=$(${SSH} core@${VM_IP} -- 'cat /proc/cmdline')

    # Get the vmlinux/initramfs to /tmp/kernel and change permission for initramfs
    ${SSH} core@${VM_IP} -- "mkdir /tmp/kernel && sudo cp -r /boot/ostree/${BASE_OS}-${ostree_hash}/*${kernel_release}* /tmp/kernel && sudo chmod 644 /tmp/kernel/initramfs*"

    # SCP the vmlinuz/initramfs from VM to Host in provided folder.
    ${SCP} -r core@${VM_IP}:/tmp/kernel/* $INSTALL_DIR

    ${SSH} core@${VM_IP} -- "sudo rm -fr /tmp/kernel"
fi

if [ ${BUNDLE_TYPE} == "snc" ]; then
    # Add internalIP as node IP for kubelet systemd unit file
    # More details at https://bugzilla.redhat.com/show_bug.cgi?id=1872632
    ${SSH} core@${VM_IP} 'sudo bash -x -s' <<EOF
    echo '[Service]' > /etc/systemd/system/kubelet.service.d/80-nodeip.conf
    echo 'Environment=KUBELET_NODE_IP="${VM_IP}"' >> /etc/systemd/system/kubelet.service.d/80-nodeip.conf
EOF
fi

podman_version=$(${SSH} core@${VM_IP} -- 'rpm -q --qf %{version} podman')

# Shutdown the VM
shutdown_vm ${VM_NAME}

# Download podman clients
download_podman $podman_version ${yq_ARCH}

# libvirt image generation
get_dest_dir_suffix "${OPENSHIFT_VERSION}"
destDirSuffix="${DEST_DIR_SUFFIX}"

libvirtDestDir="${destDirPrefix}_libvirt_${destDirSuffix}"
rm -fr ${libvirtDestDir} ${libvirtDestDir}.crcbundle
mkdir "$libvirtDestDir"

if [ $BUNDLE_TYPE != "microshift" ]; then
    create_qemu_image "$libvirtDestDir" "${VM_PREFIX}-base" "${VM_NAME}"
    mv "${libvirtDestDir}/${VM_NAME}" "${libvirtDestDir}/${SNC_PRODUCT_NAME}.qcow2"
else
    sparsify_lvm "${libvirtDestDir}"
fi
copy_additional_files "$INSTALL_DIR" "$libvirtDestDir" "${VM_NAME}"
create_tarball "$libvirtDestDir"

# vfkit image generation
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
    vfkitDestDir="${destDirPrefix}_vfkit_${destDirSuffix}"
    rm -fr ${vfkitDestDir} ${vfkitDestDir}.crcbundle
    generate_vfkit_bundle "$libvirtDestDir" "$vfkitDestDir" "$INSTALL_DIR" "$kernel_release" "$kernel_cmd_line"
fi

# HyperV image generation
#
# This must be done after the generation of libvirt image as it reuses some of
# the content of $libvirtDestDir
if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
    hypervDestDir="${destDirPrefix}_hyperv_${destDirSuffix}"
    rm -fr ${hypervDestDir} ${hypervDestDir}.crcbundle
    generate_hyperv_bundle "$libvirtDestDir" "$hypervDestDir"
fi

# Cleanup up vmlinux/initramfs files
rm -fr "$INSTALL_DIR/vmlinuz*" "$INSTALL_DIR/initramfs*"
