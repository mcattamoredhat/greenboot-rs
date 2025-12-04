#!/bin/bash
set -euox pipefail

# Color output definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color


# Dumps details about the instance running the CI job.
echo -e "\033[0;36m"
cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
     Hostname: $(uname -n)
         User: $(whoami)
         CPUs: $(nproc)
          RAM: $(free -m | grep -oP '\d+' | head -n 1) MB
         DISK: $(df --output=size -h / | sed '1d;s/[^0-9]//g') GB
         ARCH: $(uname -m)
       KERNEL: $(uname -r)
------------------------------------------------------------------------------
EOF
echo -e "\033[0m"

# Get OS info
source /etc/os-release

# Setup variables
TEST_UUID=qe-review-$((1 + RANDOM % 1000000))
TEMPDIR=$(mktemp -d)
GUEST_ADDRESS=192.168.100.50
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)
EDGE_USER=core
EDGE_USER_PASSWORD=foobar
ARCH=$(uname -m)

case "${ID}-${VERSION_ID}" in
    "rhel-9.8")
        OS_VARIANT="rhel9-unknown"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        COMPOSE_URL="${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/${COMPOSE}/compose/BaseOS/${ARCH}/iso"
        IMAGE_FILENAME="${COMPOSE}-${ARCH}-dvd1.iso"
        sudo dnf install -y make rpm-build rust-toolset
        ;;
    "rhel-10.2")
        OS_VARIANT="rhel10-unknown"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        COMPOSE_URL="${DOWNLOAD_NODE}/rhel-10/nightly/RHEL-10/${COMPOSE}/compose/BaseOS/${ARCH}/iso"
        IMAGE_FILENAME="${COMPOSE}-${ARCH}-dvd1.iso"
        sudo dnf install -y make rpm-build rust-toolset
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Validate COMPOSE_URL is set
if [[ -z "${COMPOSE_URL}" ]]; then
    echo "ERROR: COMPOSE_URL is not set for ${ID}-${VERSION_ID}"
    exit 1
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}


modksiso() {
    local isomount kspath iso newiso ksfiles ksfile ksbase newksfile oldks
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)
    iso="$1"
    newiso="$2"

    if [[ -f "${newiso}" ]]; then
        log_info "Image already exists, skipping mkksiso"
        return 0
    fi

    log_info "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    readarray -t ksfiles < <(find "${isomount}" -maxdepth 1 -name '*.ks' -print)
    if [[ ${#ksfiles[@]} -eq 0 ]]; then
        log_error "No kickstart file found in ISO"
        exit 1
    fi
    ksfile="${ksfiles[0]}"
    log_info "Found kickstart file: ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --nohome --noswap --type=plain
bootloader --append="console=tty0 console=ttyS0,115200n8"
user --name=core --groups=wheel --iscrypted --password=\$6\$1LgwKw9aOoAi/Zy9\$Pn3ErY1E8/yEanJ98evqKEW.DZp24HTuqXPJl6GYCm8uuobAmwxLv7rGCvTRZhxtcYdmC0.XnYRSR9Sh6de3p0
sshkey --username=core "${SSH_KEY_PUB}"
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
echo 'core ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
echo 'installeruser ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
%end
EOFKS

    log_info "Writing new ISO"
    sudo mkksiso -c "console=ttyS0,115200" --rm-args "quiet" "${newksfile}" "${iso}" "${newiso}"

    log_info "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    log_info "============================"

    # Clean up
    log_info "Unmounting ISO and cleaning up"
    sudo umount -v "${isomount}" || true
    rm -rf "${isomount}" "${kspath}"
}

download_image() {
    log_info "Downloading OS image..."
    
    local image_url="${COMPOSE_URL}/${IMAGE_FILENAME}"
    
    if [[ -f "${IMAGE_FILENAME}" ]]; then
        log_info "Image already exists, skipping download"
        return 0
    fi
    
    if ! sudo wget --progress=bar:force "${image_url}"; then
        log_error "Failed to download image from ${image_url}"
        exit 1
    fi
    
    if [[ -f "${IMAGE_FILENAME}" ]]; then
        log_success "Download completed: ${IMAGE_FILENAME}"
    else
        log_error "Downloaded file not found: ${IMAGE_FILENAME}"
        exit 1
    fi
}

check_result () {
    log_info "🎏 Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        log_success "💚 Success"
    else
        log_error "❌ Failed"
        exit 1
    fi
}

# Wait for the ssh server up to be.
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" ${EDGE_USER}@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

###########################################################
##
## Prepare before run test
##
###########################################################
log_info "Installing required packages"
sudo dnf install -y podman qemu-img firewalld qemu-kvm libvirt-client libvirt-daemon-kvm libvirt-daemon virt-install rpmdevtools ansible-core cargo lorax gobject-introspection
ansible-galaxy collection install community.general

# Start firewalld
log_info "Start firewalld"
sudo systemctl enable --now firewalld

# Check ostree_key permissions
KEY_PERMISSION_PRE=$(stat -L -c "%a %G %U" key/ostree_key | grep -oP '\d+' | head -n 1)
echo -e "${KEY_PERMISSION_PRE}"
if [[ "${KEY_PERMISSION_PRE}" != "600" ]]; then
   log_info "💡 File permissions too open...Changing to 600"
   chmod 600 ./key/ostree_key
fi

# Setup libvirt
log_info "Starting libvirt service and configure libvirt network"
sudo tee /etc/polkit-1/rules.d/50-libvirt.rules > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.unix.manage" &&
        subject.isInGroup("adm")) {
            return polkit.Result.YES;
    }
});
EOF
sudo systemctl start libvirtd
sudo virsh list --all > /dev/null
sudo tee /tmp/integration.xml > /dev/null << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm-1' ip='192.168.100.50'/>
      <host mac='34:49:22:B0:83:31' name='vm-2' ip='192.168.100.51'/>
      <host mac='34:49:22:B0:83:32' name='vm-3' ip='192.168.100.52'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='dhcp-vendorclass=set:efi-http,HTTPClient:Arch:00016'/>
    <dnsmasq:option value='dhcp-option-force=tag:efi-http,60,HTTPClient'/>
    <dnsmasq:option value='dhcp-boot=tag:efi-http,&quot;http://192.168.100.1/httpboot/EFI/BOOT/BOOTX64.EFI&quot;'/>
  </dnsmasq:options>
</network>
EOF
if ! sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-define /tmp/integration.xml
fi
if [[ $(sudo virsh net-info integration | grep 'Active' | awk '{print $2}') == 'no' ]]; then
    sudo virsh net-start integration
fi

###########################################################
##
## Build greenboot rpm packages
##
###########################################################
log_info "Building greenboot packages"
pushd .. && \
make rpm
cp rpmbuild/RPMS/x86_64/*.rpm tests/
cp testing_assets/passing_script.sh tests/
cp testing_assets/passing_binary tests/
cp testing_assets/failing_script.sh tests/
cp testing_assets/failing_binary tests/ && popd


## Download pre-built ISO from compose URL
download_image
# Modify ISO and copy to libvirt images directory
modksiso "${IMAGE_FILENAME}" "/var/lib/libvirt/images/${IMAGE_FILENAME}"

sudo restorecon -Rv /var/lib/libvirt/images/

###########################################################
##
## Provision vm with pre-built ISO
##
###########################################################
log_info "Installing vm with pre-built ISO image"
log_info "💾 Create vm qcow2 files for ISO installation"
LIBVIRT_IMAGE_PATH_UEFI=/var/lib/libvirt/images/${TEST_UUID}-disk.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_IMAGE_PATH_UEFI}" 10G
sudo restorecon -Rv /var/lib/libvirt/images/
sudo virt-install  --name="${TEST_UUID}-uefi"\
                   --disk path="${LIBVIRT_IMAGE_PATH_UEFI}",format=qcow2 \
                   --ram 4096 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant ${OS_VARIANT} \
                   --cdrom "/var/lib/libvirt/images/${IMAGE_FILENAME}" \
                   --boot ${BOOT_ARGS} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot
log_info "Starting UEFI VM"
sudo virsh start "${TEST_UUID}-uefi"

# Check for ssh ready to go.
log_info "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done
check_result
exit 0

