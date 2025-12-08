#!/bin/bash
#bashsupport disable=GrazieInspection
#
# Kubuntu 24.10 Installation Script with ZFS and LUKS Encryption
#
# This script automates the installation of Kubuntu with:
#   - ZFS root filesystem
#   - LUKS2 encryption for data and swap
#   - EFI boot support
#   - KDE Plasma desktop
#   - Hibernation support
#
# Based on: https://medo64.com/series/kubuntu-install/
# Style: Google Shell Style Guide
#
# Usage:
#   sudo ./kubuntu_zfs_install.sh [--disk disk] [--hostname NAME] [--user USER]
#
# Requirements:
#   - Boot from Kubuntu live USB
#   - Run as root (sudo -i)
#   - Internet connection
#

set -o errexit
set -o nounset
set -o pipefail

#######################################
# Constants
#######################################
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# Default configuration values
readonly DEFAULT_SWAP_SIZE_GB=64
readonly DEFAULT_SYSTEM_QUOTA_GB=100
readonly EFI_SIZE_MB=255
readonly BOOT_SIZE_MB=1792

# ZFS dataset names
readonly POOL_NAME="System"
readonly DATASET_ROOT="${POOL_NAME}/Root"
readonly DATASET_HOME="${POOL_NAME}/Home"
readonly DATASET_DATA="${POOL_NAME}/Data"
readonly DATASET_VBOX="${POOL_NAME}/VirtualBox"

# Mount points
readonly INSTALL_POINT="/mnt/install"

# Color codes for output (empty if not terminal)



#######################################
# Print error message to stderr.
# Globals:
#   red, nc
# Arguments:
#   Error message string
# Outputs:
#   Writes error message to stderr
#######################################
err() {
  echo -e "${red}[ERROR]${nc} $*" >&2
}

#######################################
# Print warning message to stderr.
# Globals:
#   yellow, nc
# Arguments:
#   Warning message string
# Outputs:
#   Writes the warning message to stderr
#######################################
warn() {
  echo -e "${yellow}[WARN]${nc} $*" >&2
}

#######################################
# Print info message to stdout.
# Globals:
#   green, nc
# Arguments:
#   Info message string
# Outputs:
#   Writes an info message to stdout
#######################################
info() {
  echo -e "${green}[INFO]${nc} $*"
}

#######################################
# Print a step header to stdout.
# Globals:
#   blue, nc
# Arguments:
#   Step description string
# Outputs:
#   Writes step header to stdout
#######################################
step() {
  echo -e "\n${blue}==>${nc} $*"
}

#######################################
# Print usage information and exit.
# Globals:
#   SCRIPT_NAME
# Arguments:
#   None
# Outputs:
#   Writes usage info to stdout
#######################################
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Kubuntu 24.10 Installation with ZFS and LUKS Encryption

Options:
  -d, --disk DISK       Target disk device (e.g., /dev/nvme0n1)
  -h, --hostname NAME   System hostname
  -u, --user USERNAME   Primary user account name
  -s, --swap SIZE       Swap size in GB (default: ${DEFAULT_SWAP_SIZE_GB})
  -y, --yes             Non-interactive mode (skip confirmations)
  --help                Show this help message

Examples:
  ${SCRIPT_NAME} --disk /dev/nvme0n1 --hostname mypc --user johndoe
  ${SCRIPT_NAME} -d /dev/sda -h workstation -u admin -s 32

WARNING: This script will DESTROY all data on the target disk!
EOF
  exit 0
}

#######################################
# Check if running as root.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 is root, 1 otherwise
#######################################
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root (sudo -i)"
    return 1
  fi
  return 0
}

#######################################
# Check if running from a live environment.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 in live environment, 1 otherwise
#######################################
check_live_environment() {
  if [[ ! -d /cdrom ]] && [[ ! -d /run/live ]]; then
    warn "Not detected as live environment. Proceeding anyway..."
  fi
  return 0
}

#######################################
# Validate disk device exists.
# Globals:
#   disk
# Arguments:
#   None
# Returns:
#   0 if valid, 1 otherwise
#######################################
validate_disk() {
  if [[ -z "${disk}" ]]; then
    err "No disk specified. Use --disk option."
    return 1
  fi

  if [[ ! -b "${disk}" ]]; then
    err "Disk '${disk}' is not a valid block device"
    return 1
  fi

  return 0
}

#######################################
# Prompt user for confirmation.
# Globals:
#   interactive
# Arguments:
#   Prompt message
# Returns:
#   0 if confirmed, 1 otherwise
#######################################
confirm() {
  local prompt="$1" response

  if [[ "${interactive}" != true ]]; then
    return 0
  fi

  read -r -p "${prompt} [y/N]: " response
  case "${response}" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

#######################################
# Install required packages in a live environment.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
install_live_packages() {
  step "Installing required packages in live environment"

  apt-get update
  apt-get install -y gdisk zfsutils-linux debootstrap
}

#######################################
# Calculate the last aligned sector for 4K drives.
# Globals:
#   disk
# Arguments:
#   None
# Outputs:
#   Writes last aligned sector to stdout
#######################################
get_last_aligned_sector() {
  local total_sectors
  local sector_size
  local alignment

  total_sectors=$(blockdev --getsz "${disk}")
  sector_size=$(blockdev --getss "${disk}")
  alignment=$((4096 / sector_size))

  echo $(( (total_sectors / alignment) * alignment - 1 ))
}

#######################################
# Partition the target disk.
# Globals:
#   disk, EFI_SIZE_MB, BOOT_SIZE_MB, swap_size_gb
#   part_efi, part_boot, part_swap, part_data
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
partition_disk() {
  step "Partitioning disk: ${disk}"

  local last_sector
  last_sector=$(get_last_aligned_sector)

  # Determine partition naming scheme (nvme vs standard)
  local part_prefix="${disk}"
  if [[ "${disk}" == *"nvme"* ]] || [[ "${disk}" == *"mmcblk"* ]]; then
    part_prefix="${disk}p"
  fi

  part_efi="${part_prefix}1"
  part_boot="${part_prefix}2"
  part_swap="${part_prefix}3"
  part_data="${part_prefix}4"

  info "Wiping existing partition table..."
  blkdiscard -f "${disk}" 2>/dev/null || wipefs -a "${disk}"
  sgdisk --zap-all "${disk}"

  info "Creating partitions..."

  # EFI System Partition (ESP)
  sgdisk --new=1:0:+"${EFI_SIZE_MB}"M \
         --typecode=1:EF00 \
         --change-name=1:"EFI" \
         "${disk}"

  # Boot partition
  sgdisk --new=2:0:+"${BOOT_SIZE_MB}"M \
         --typecode=2:8300 \
         --change-name=2:"Boot" \
         "${disk}"

  # Swap partition (LUKS encrypted)
  sgdisk --new=3:0:+"${swap_size_gb}"G \
         --typecode=3:8200 \
         --change-name=3:"Swap" \
         "${disk}"

  # Data partition (LUKS encrypted, remaining space)
  sgdisk --new=4:0:"${last_sector}" \
         --typecode=4:8309 \
         --change-name=4:"Data" \
         "${disk}"

  # Inform the kernel of partition changes
  partprobe "${disk}"
  sleep 2

  info "Partitions created:"
  info "  EFI:  ${part_efi}"
  info "  Boot: ${part_boot}"
  info "  Swap: ${part_swap}"
  info "  Data: ${part_data}"
}

#######################################
# Retrieve partition UUIDs.
# Globals:
#   part_swap, part_data, uuid_swap, uuid_data
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
get_partition_uuids() {
  uuid_swap=$(blkid -s UUID -o value "${part_swap}")
  uuid_data=$(blkid -s UUID -o value "${part_data}")

  info "Partition UUIDs:"
  info "  Swap: ${uuid_swap}"
  info "  Data: ${uuid_data}"
}

#######################################
# Setup LUKS encryption on partitions.
# Globals:
#   part_swap, part_data, uuid_swap, uuid_data
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
setup_luks_encryption() {
  step "Setting up LUKS encryption"

  local luks_options=(
    --type luks2
    --cipher aes-xts-plain64
    --key-size 256
    --hash sha256
    --pbkdf argon2i
    --iter-time 3000
    --verify-passphrase
  )

  info "Encrypting swap partition..."
  info "You will be prompted to enter and verify a passphrase."
  cryptsetup luksFormat "${luks_options[@]}" "${part_swap}"

  info "Encrypting data partition..."
  info "You will be prompted to enter and verify a passphrase."
  cryptsetup luksFormat "${luks_options[@]}" "${part_data}"

  # Retrieve UUIDs after LUKS formatting
  get_partition_uuids

  info "Opening encrypted partitions..."
  cryptsetup luksOpen "${part_swap}" "luks-${uuid_swap}"
  cryptsetup luksOpen "${part_data}" "luks-${uuid_data}"

  # Set persistence flags
  cryptsetup --persistent --allow-discards \
    --perf-no_read_workqueue --perf-no_write_workqueue \
    refresh "luks-${uuid_data}"
}

#######################################
# Create ZFS pool and datasets.
# Globals:
#   uuid_data, POOL_NAME, DATASET_ROOT, DATASET_HOME
#   DATASET_DATA, DATASET_VBOX, DEFAULT_SYSTEM_QUOTA_GB
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
create_zfs_pool() {
  step "Creating ZFS pool and datasets"

  local pool_device="/dev/mapper/luks-${uuid_data}"

  info "Creating ZFS pool: ${POOL_NAME}"
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O compression=lz4 \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O canmount=off \
    -O mountpoint=none \
    "${POOL_NAME}" "${pool_device}"

  info "Creating root dataset: ${DATASET_ROOT}"
  zfs create \
    -o canmount=noauto \
    -o mountpoint=/ \
    -o reservation="${DEFAULT_SYSTEM_QUOTA_GB}G" \
    -o quota="${DEFAULT_SYSTEM_QUOTA_GB}G" \
    "${DATASET_ROOT}"

  info "Creating home dataset: ${DATASET_HOME}"
  zfs create \
    -o canmount=on \
    -o mountpoint=/home \
    "${DATASET_HOME}"

  info "Creating data dataset: ${DATASET_DATA}"
  zfs create \
    -o canmount=on \
    -o mountpoint=/data \
    "${DATASET_DATA}"

  info "Creating VirtualBox dataset: ${DATASET_VBOX}"
  zfs create \
    -o canmount=on \
    -o mountpoint=/data/VirtualBox \
    -o recordsize=32K \
    "${DATASET_VBOX}"

  # Disable device nodes on pool
  zfs set devices=off "${POOL_NAME}"

  # Export and reimport to the installation point
  zpool export "${POOL_NAME}"
  zpool import -R "${INSTALL_POINT}" "${POOL_NAME}"
  zfs mount "${DATASET_ROOT}"
}

#######################################
# Format and mount boot partitions.
# Globals:
#   part_efi, part_boot, part_swap, uuid_swap, INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
setup_boot_partitions() {
  step "Setting up boot partitions"

  info "Formatting boot partition as ext4..."
  mkfs.ext4 -q -F "${part_boot}"

  info "Formatting EFI partition as FAT32..."
  mkfs.fat -F 32 "${part_efi}"

  info "Mounting boot partitions..."
  mkdir -p "${INSTALL_POINT}/boot"
  mount "${part_boot}" "${INSTALL_POINT}/boot"

  mkdir -p "${INSTALL_POINT}/boot/efi"
  mount "${part_efi}" "${INSTALL_POINT}/boot/efi"

  info "Initializing swap..."
  mkswap "/dev/mapper/luks-${uuid_swap}"
}

#######################################
# Bootstrap the base system.
# Globals:
#   INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
bootstrap_system() {
  step "Bootstrapping Kubuntu base system"

  local release="oracular"  # Kubuntu 24.10

  info "Running debootstrap (this may take a while)..."
  debootstrap --arch=amd64 "${release}" "${INSTALL_POINT}" \
    http://archive.ubuntu.com/ubuntu
}

#######################################
# Configure the system hostname.
# Globals:
#   hostname_target, INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
configure_hostname() {
  step "Configuring hostname: ${hostname_target}"

  echo "${hostname_target}" > "${INSTALL_POINT}/etc/hostname"

  cat > "${INSTALL_POINT}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname_target}

# IPv6 localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
}

#######################################
# Setup network configuration.
# Globals:
#   INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
setup_network() {
  step "Configuring network"

  mkdir -p "${INSTALL_POINT}/etc/netplan"

  # Copy existing netplan config if available
  if [[ -d /etc/netplan ]]; then
    cp -a /etc/netplan/* "${INSTALL_POINT}/etc/netplan/" 2>/dev/null || true
  fi

  # Create basic DHCP configuration as a fallback
  if [[ ! -f "${INSTALL_POINT}/etc/netplan/01-network.yaml" ]]; then
    cat > "${INSTALL_POINT}/etc/netplan/01-network.yaml" <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
  fi
}

#######################################
# Mount system directories for chroot.
# Globals:
#   INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
mount_chroot_dirs() {
  step "Mounting system directories for chroot"

  mount --bind /dev "${INSTALL_POINT}/dev"
  mount --bind /dev/pts "${INSTALL_POINT}/dev/pts"
  mount -t proc proc "${INSTALL_POINT}/proc"
  mount -t sysfs sysfs "${INSTALL_POINT}/sys"
  mount -t efivarfs efivarfs "${INSTALL_POINT}/sys/firmware/efi/efivars" \
    2>/dev/null || true
}

#######################################
# Generate the chroot configuration script.
# Globals:
#   hostname_target, username, uuid_swap, uuid_data
#   part_efi, part_boot
# Arguments:
#   None
# Outputs:
#   Writes the script path to stdout
#######################################
# bashsupport disable=SpellCheckingInspection
generate_chroot_script() {
  local script_path="${INSTALL_POINT}/tmp/chroot-setup.sh"

  cat > "${script_path}" <<'CHROOT_SCRIPT'
#!/bin/bash
#
# Chroot configuration script
# Generated by kubuntu-zfs-install.sh
#

set -o errexit
set -o nounset
set -o pipefail

# Variables passed from the parent script
HOSTNAME_TARGET="__HOSTNAME__"
USERNAME="__USERNAME__"
UUID_SWAP="__UUID_SWAP__"
UUID_DATA="__UUID_DATA__"
PART_EFI="__PART_EFI__"
PART_BOOT="__PART_BOOT__"

info() {
  echo "[INFO] $*"
}

step() {
  echo ""
  echo "==> $*"
}

#######################################
# Configure locale and timezone
#######################################
configure_locale() {
  step "Configuring locale and timezone"

  # Set locale
  locale-gen en_US.UTF-8
  update-locale LANG=en_US.UTF-8

  # Configure timezone interactively
  dpkg-reconfigure tzdata
}

#######################################
# Create crypttab entries
#######################################
create_crypttab() {
  step "Creating /etc/crypttab"

  cat > /etc/crypttab <<EOF
luks-${UUID_SWAP} UUID=${UUID_SWAP} none luks,discard,keyscript=decrypt_keyctl
luks-${UUID_DATA} UUID=${UUID_DATA} none luks,discard,keyscript=decrypt_keyctl
EOF
}

#######################################
# Create fstab entries
#######################################
create_fstab() {
  step "Creating /etc/fstab"

  local efi_uuid
  local boot_uuid

  efi_uuid=$(blkid -s UUID -o value "${PART_EFI}")
  boot_uuid=$(blkid -s UUID -o value "${PART_BOOT}")

  cat > /etc/fstab <<EOF
# <file system>                           <mount point>  <type>  <options>                    <dump> <pass>
# Boot partition
UUID=${boot_uuid}                         /boot          ext4    defaults,nofail              0      2
# EFI System Partition
UUID=${efi_uuid}                          /boot/efi      vfat    umask=0077,nofail            0      1
# Swap (encrypted)
/dev/mapper/luks-${UUID_SWAP}             none           swap    sw,discard                   0      0
EOF
}

#######################################
# Install kernel and boot components
#######################################
install_kernel() {
  step "Installing kernel and boot components"

  # Add universe repository
  cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: oracular oracular-updates oracular-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

  apt-get update

  # Install kernel
  apt-get install -y linux-generic linux-headers-generic

  # Install ZFS and encryption support
  apt-get install -y zfsutils-linux zfs-initramfs cryptsetup keyutils

  # Install GRUB
  apt-get install -y grub-efi-amd64-signed shim-signed

  # Install Plymouth for boot splash
  apt-get install -y plymouth plymouth-theme-spinner
}

#######################################
# Configure kernel parameters
#######################################
configure_kernel() {
  step "Configuring kernel parameters"

  # Memory management settings
  cat > /etc/sysctl.d/99-custom.conf <<EOF
# Reduce swappiness for SSD
vm.swappiness=10

# Increase minimum free memory
vm.min_free_kbytes=65536
EOF
}

#######################################
# Configure GRUB bootloader
#######################################
configure_grub() {
  step "Configuring GRUB"

  local swap_mapper_uuid
  swap_mapper_uuid=$(blkid -s UUID -o value "/dev/mapper/luks-${UUID_SWAP}")

  # Update GRUB configuration
  cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Kubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="root=ZFS=System/Root resume=UUID=${swap_mapper_uuid}"
GRUB_TERMINAL=console
EOF

  # Update initramfs
  update-initramfs -c -k all

  # Install GRUB to EFI
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=ubuntu --recheck

  # Generate GRUB configuration
  update-grub
}

#######################################
# Remove snapd and configure apt
#######################################
configure_packages() {
  step "Configuring package management"

  # Remove snapd if present
  apt-get purge -y snapd 2>/dev/null || true

  # Prevent snapd from being installed
  cat > /etc/apt/preferences.d/no-snap.pref <<EOF
Package: snapd
Pin: release a=*
Pin-Priority: -1
EOF

  apt-get update
}

#######################################
# Install KDE Plasma desktop
#######################################
install_desktop() {
  step "Installing KDE Plasma desktop"

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    kde-plasma-desktop \
    plasma-nm \
    sddm \
    konsole \
    dolphin \
    kate \
    man-db \
    wget \
    curl \
    vim \
    network-manager
}

#######################################
# Configure hibernation support
#######################################
configure_hibernation() {
  step "Configuring hibernation support"

  apt-get install -y pm-utils

  # Enable hibernation
  mkdir -p /etc/systemd/sleep.conf.d
  cat > /etc/systemd/sleep.conf.d/hibernate.conf <<EOF
[Sleep]
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=780
EOF

  # Configure power button and lid behavior
  mkdir -p /etc/systemd/logind.conf.d
  cat > /etc/systemd/logind.conf.d/power.conf <<EOF
[Login]
HandlePowerKey=hibernate
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=ignore
HoldoffTimeoutSec=13s
EOF
}

#######################################
# Install Firefox from Mozilla PPA
#######################################
install_firefox() {
  step "Installing Firefox"

  add-apt-repository -y ppa:mozillateam/ppa

  # Prioritize PPA version
  cat > /etc/apt/preferences.d/mozilla-ppa.pref <<EOF
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF

  apt-get update
  apt-get install -y firefox
}

#######################################
# Create user account
#######################################
create_user() {
  step "Creating user account: ${USERNAME}"

  # Create a user with a disabled password initially
  useradd -m -s /bin/bash -G adm,cdrom,sudo,dip,plugdev "${USERNAME}"

  # Configure passwordless sudo for initial setup
  echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
  chmod 440 "/etc/sudoers.d/${USERNAME}"

  info "Setting password for ${USERNAME}..."
  passwd "${USERNAME}"

  # Remove passwordless sudo after password is set
  rm -f "/etc/sudoers.d/${USERNAME}"
}

#######################################
# Main chroot execution
#######################################
main() {
  configure_locale
  create_crypttab
  create_fstab
  install_kernel
  configure_kernel
  configure_grub
  configure_packages
  install_desktop
  configure_hibernation
  install_firefox
  create_user

  info "Chroot configurations complete!"
}

main "$@"
CHROOT_SCRIPT

  # Replace placeholders with actual values
  sed -i "s|__HOSTNAME__|${hostname_target}|g" "${script_path}"
  sed -i "s|__USERNAME__|${username}|g" "${script_path}"
  sed -i "s|__UUID_SWAP__|${uuid_swap}|g" "${script_path}"
  sed -i "s|__UUID_DATA__|${uuid_data}|g" "${script_path}"
  sed -i "s|__PART_EFI__|${part_efi}|g" "${script_path}"
  sed -i "s|__PART_BOOT__|${part_boot}|g" "${script_path}"

  chmod +x "${script_path}"
  echo "${script_path}"
}

#######################################
# Execute chroot setup.
# Globals:
#   INSTALL_POINT
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
run_chroot_setup() {
  step "Running chroot configuration"

  local script_path
  script_path=$(generate_chroot_script)

  chroot "${INSTALL_POINT}" /tmp/chroot-setup.sh

  rm -f "${script_path}"
}

#######################################
# Cleanup and unmount filesystems.
# Globals:
#   INSTALL_POINT, POOL_NAME, uuid_swap, uuid_data
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
cleanup() {
  step "Cleaning up and unmounting filesystems"

  # Exit chroot (handled by script completion)

  # Disable devices on System dataset
  zfs set devices=off "${DATASET_ROOT}" 2>/dev/null || true

  # Sync filesystems
  sync

  # Unmount in reverse order
  umount -R "${INSTALL_POINT}/sys/firmware/efi/efivars" 2>/dev/null || true
  umount -R "${INSTALL_POINT}/sys" 2>/dev/null || true
  umount -R "${INSTALL_POINT}/proc" 2>/dev/null || true
  umount -R "${INSTALL_POINT}/dev/pts" 2>/dev/null || true
  umount -R "${INSTALL_POINT}/dev" 2>/dev/null || true
  umount "${INSTALL_POINT}/boot/efi" 2>/dev/null || true
  umount "${INSTALL_POINT}/boot" 2>/dev/null || true

  # Export ZFS pool
  zpool export -a 2>/dev/null || true

  # Close LUKS devices
  cryptsetup luksClose "luks-${uuid_swap}" 2>/dev/null || true
  cryptsetup luksClose "luks-${uuid_data}" 2>/dev/null || true

  info "Cleanup complete."
}

#######################################
# Parse command line arguments.
# Globals:
#   disk, hostname_target, username, swap_size_gb, interactive
# Arguments:
#   Command line arguments
# Returns:
#   0 on success
#######################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--disk)
        disk="$2"
        shift 2
        ;;
      -h|--hostname)
        hostname_target="$2"
        shift 2
        ;;
      -u|--user)
        username="$2"
        shift 2
        ;;
      -s|--swap)
        swap_size_gb="$2"
        shift 2
        ;;
      -y|--yes)
        interactive=false
        shift
        ;;
      --help)
        usage
        ;;
      *)
        err "Unknown option: $1"
        usage
        ;;
    esac
  done
}

#######################################
# Prompt for missing required values.
# Globals:
#   disk, hostname_target, username, interactive
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
prompt_missing_values() {
  if [[ -z "${disk}" ]]; then
    info "Available disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "^loop"
    echo ""
    read -r -p "Enter target disk (e.g., /dev/nvme0n1): " disk
  fi

  if [[ -z "${hostname_target}" ]]; then
    read -r -p "Enter system hostname: " hostname_target
  fi

  if [[ -z "${username}" ]]; then
    read -r -p "Enter primary username: " username
  fi
}

#######################################
# Display installation summary.
# Globals:
#   disk, hostname_target, username, swap_size_gb
# Arguments:
#   None
# Outputs:
#   Writes summary to stdout
#######################################
display_summary() {
  echo ""
  echo "============================================"
  echo "  Kubuntu Installation Summary"
  echo "============================================"
  echo "  Target Disk:    ${disk}"
  echo "  Hostname:       ${hostname_target}"
  echo "  Username:       ${username}"
  echo "  Swap Size:      ${swap_size_gb} GB"
  echo "  ZFS Pool:       ${POOL_NAME}"
  echo "============================================"
  echo ""
  warn "WARNING: ALL DATA ON ${disk} WILL BE DESTROYED!"
  echo ""
}

#######################################
# Main installation routine.
# Globals:
#   All global variables
# Arguments:
#   Command line arguments
# Returns:
#   0 on success
#######################################
main() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Kubuntu 24.10 Installation with ZFS and LUKS Encryption   ║"
  echo "║  Version: ${SCRIPT_VERSION}                                         ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  #######################################
  # Global variables (set during runtime)
  #######################################
  disk=""
  hostname_target=""
  username=""
  swap_size_gb="${DEFAULT_SWAP_SIZE_GB}"
  interactive=true

  # Partition variables (populated after partitioning)
  part_efi=""
  part_boot=""
  part_swap=""
  part_data=""
  uuid_swap=""
  uuid_data=""

  if [[ -t 1 ]]; then
    readonly red='\033[0;31m'
    readonly green='\033[0;32m'
    readonly yellow='\033[0;33m'
    readonly blue='\033[0;34m'
    readonly nc='\033[0m'
  else
    readonly red=''
    readonly green=''
    readonly yellow=''
    readonly blue=''
    readonly nc=''
  fi
  parse_args "$@"

  check_root || exit 1
  check_live_environment

  prompt_missing_values
  validate_disk || exit 1

  display_summary

  if ! confirm "Proceed with installation?"; then
    info "Installation cancelled by user."
    exit 0
  fi

  # Set up a trap for cleanup on error
  trap cleanup EXIT

  install_live_packages
  partition_disk
  setup_luks_encryption
  create_zfs_pool
  setup_boot_partitions
  bootstrap_system
  configure_hostname
  setup_network
  mount_chroot_dirs
  run_chroot_setup

  # Remove trap before final cleanup
  trap - EXIT
  cleanup

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║              Installation Complete!                        ║"
  echo "╠════════════════════════════════════════════════════════════╣"
  echo "║  Remove the installation media and reboot your system.     ║"
  echo "║                                                            ║"
  echo "║  Post-boot steps:                                          ║"
  echo "║  1. Log in as: ${username}                                 ║"
  echo "║  2. Set local time: timedatectl set-local-rtc 1            ║"
  echo "║  3. Test hibernation: systemctl hibernate                  ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  if confirm "Reboot now?"; then
    reboot
  fi
}

main "$@"
