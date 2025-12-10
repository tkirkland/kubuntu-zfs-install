#!/bin/bash
#bashsupport disable=GrazieInspection
#
# Kubuntu 24.10 Installation Script with ZFS (No Encryption)
#
# This script automates the installation of Kubuntu with:
#   - ZFS root filesystem (direct, no encryption)
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

set -o errexit
set -o nounset
set -o pipefail

#######################################
# Constants
#######################################
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# Disks - use /dev/disk/by-id/ paths for stability
readonly DISK1="/dev/disk/by-id/nvme-eui.0025384331408197"
readonly DISK2="/dev/disk/by-id/nvme-eui.002538433140818a"
readonly DISK3="/dev/disk/by-id/nvme-eui.002538433140819d"

# System configuration
readonly DEFAULT_HOST="precision"
readonly DEFAULT_USERNAME="me"
readonly DEFAULT_USERID="1000"

# Partition sizes
readonly EFI_SIZE="512M"
readonly BOOT_SIZE="1792M"
readonly SWAP_SIZE="4G"

# ZFS configuration
readonly DEFAULT_SYSTEM_QUOTA_GB=100

# ZFS dataset names
readonly POOL_NAME="System"
readonly DATASET_ROOT="${POOL_NAME}/Root"
readonly DATASET_HOME="${POOL_NAME}/Home"
readonly DATASET_DATA="${POOL_NAME}/Data"
readonly DATASET_VBOX="${POOL_NAME}/VirtualBox"

# Mount points
readonly INSTALL_POINT="/mnt/install"

# Locale fallback (used if auto-detection fails)
readonly FALLBACK_LOCALE="en_US.UTF-8"
readonly FALLBACK_TIMEZONE="America/New_York"

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

Kubuntu 24.10 Installation with ZFS RAIDZ (No Encryption)

This script installs Kubuntu on a 3-disk RAIDZ1 configuration using:
  - ${DISK1}
  - ${DISK2}
  - ${DISK3}

Options:
  -h, --hostname NAME   System hostname (default: ${DEFAULT_HOST})
  -u, --user USERNAME   Primary user account name (default: ${DEFAULT_USERNAME})
  -y, --yes             Non-interactive mode (skip confirmations)
  --help                Show this help message

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --hostname mypc --user johndoe
  ${SCRIPT_NAME} -y

WARNING: This script will DESTROY all data on ALL THREE target disks!
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
  apt-get install -y gdisk zfsutils-linux
}

#######################################
# Find the Kubuntu squashfs filesystem image.
# Globals:
#   squashfs_path
# Arguments:
#   None
# Returns:
#   0 if found, 1 otherwise
#######################################
find_squashfs() {
  step "Locating squashfs filesystem image"

  # Common locations for squashfs on Ubuntu/Kubuntu live systems
  local search_paths=(
    "/cdrom/casper/filesystem.squashfs"
    "/run/live/medium/casper/filesystem.squashfs"
    "/media/cdrom/casper/filesystem.squashfs"
    "/lib/live/mount/medium/casper/filesystem.squashfs"
  )

  for path in "${search_paths[@]}"; do
    if [[ -f "${path}" ]]; then
      squashfs_path="${path}"
      info "Found squashfs at: ${squashfs_path}"
      return 0
    fi
  done

  # Try to find it with find command as fallback
  local found_path
  found_path=$(find /cdrom /run/live /media /lib/live \
    -name "filesystem.squashfs" -type f 2>/dev/null | head -n 1)

  if [[ -n "${found_path}" ]]; then
    squashfs_path="${found_path}"
    info "Found squashfs at: ${squashfs_path}"
    return 0
  fi

  err "Could not find filesystem.squashfs"
  err "Searched in: ${search_paths[*]}"
  return 1
}

#######################################
# Get partition path for a disk.
# Arguments:
#   $1 - disk path
#   $2 - partition number
# Outputs:
#   Writes partition path to stdout
#######################################
get_partition_path() {
  local disk="$1"
  local partnum="$2"

  # Determine partition naming scheme (nvme/mmcblk vs standard)
  if [[ "${disk}" == *"nvme"* ]] || [[ "${disk}" == *"mmcblk"* ]]; then
    echo "${disk}-part${partnum}"
  else
    echo "${disk}-part${partnum}"
  fi
}

#######################################
# Partition a single disk for RAIDZ setup.
# Arguments:
#   $1 - disk path
#   $2 - disk number (1, 2, or 3)
# Returns:
#   0 on success
#######################################
partition_single_disk() {
  local disk="$1"
  local disk_num="$2"

  info "Partitioning disk ${disk_num}: ${disk}"

  # Wipe existing partition table
  blkdiscard -f "${disk}" 2>/dev/null || wipefs -a "${disk}"
  sgdisk --zap-all "${disk}"

  if [[ "${disk_num}" -eq 1 ]]; then
    # First disk: EFI + Boot + Swap + Data
    sgdisk --new=1:0:+"${EFI_SIZE}" \
           --typecode=1:EF00 \
           --change-name=1:"EFI" \
           "${disk}"

    sgdisk --new=2:0:+"${BOOT_SIZE}" \
           --typecode=2:8300 \
           --change-name=2:"Boot" \
           "${disk}"

    sgdisk --new=3:0:+"${SWAP_SIZE}" \
           --typecode=3:8200 \
           --change-name=3:"Swap" \
           "${disk}"

    sgdisk --new=4:0:0 \
           --typecode=4:BF00 \
           --change-name=4:"Data" \
           "${disk}"
  else
    # Other disks: Only Data partition (full disk)
    sgdisk --new=1:0:0 \
           --typecode=1:BF00 \
           --change-name=1:"Data" \
           "${disk}"
  fi

  # Inform the kernel of partition changes
  partprobe "${disk}"
}

#######################################
# Partition all target disks for RAIDZ.
# Globals:
#   DISK1, DISK2, DISK3, EFI_SIZE, BOOT_SIZE, SWAP_SIZE
#   part_efi, part_boot, part_swap
#   part_data1, part_data2, part_data3
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
partition_disks() {
  step "Partitioning all disks for RAIDZ1"

  # Partition each disk
  partition_single_disk "${DISK1}" 1
  partition_single_disk "${DISK2}" 2
  partition_single_disk "${DISK3}" 3

  # Wait for partitions to appear
  sleep 2

  # Set partition paths for DISK1 (boot disk)
  part_efi=$(get_partition_path "${DISK1}" 1)
  part_boot=$(get_partition_path "${DISK1}" 2)
  part_swap=$(get_partition_path "${DISK1}" 3)

  # Set data partition paths for all disks
  part_data1=$(get_partition_path "${DISK1}" 4)
  part_data2=$(get_partition_path "${DISK2}" 1)
  part_data3=$(get_partition_path "${DISK3}" 1)

  info "Partitions created:"
  info "  DISK1 (boot disk):"
  info "    EFI:  ${part_efi}"
  info "    Boot: ${part_boot}"
  info "    Swap: ${part_swap}"
  info "    Data: ${part_data1}"
  info "  DISK2:"
  info "    Data: ${part_data2}"
  info "  DISK3:"
  info "    Data: ${part_data3}"
}


#######################################
# Create ZFS RAIDZ1 pool and datasets.
# Globals:
#   part_data1, part_data2, part_data3, POOL_NAME
#   DATASET_ROOT, DATASET_HOME, DATASET_DATA, DATASET_VBOX
#   DEFAULT_SYSTEM_QUOTA_GB
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
create_zfs_pool() {
  step "Creating ZFS RAIDZ1 pool and datasets"

  info "Creating ZFS pool: ${POOL_NAME} (RAIDZ1)"
  info "  Using devices:"
  info "    - ${part_data1}"
  info "    - ${part_data2}"
  info "    - ${part_data3}"

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
    "${POOL_NAME}" raidz1 "${part_data1}" "${part_data2}" "${part_data3}"

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
#   part_efi, part_boot, part_swap, INSTALL_POINT
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
  mkswap "${part_swap}"
}

#######################################
# Copy the base system from squashfs.
# Globals:
#   INSTALL_POINT, squashfs_path
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
copy_system_from_squashfs() {
  step "Copying system from squashfs image"

  local squashfs_mount="/mnt/squashfs"

  info "Mounting squashfs image..."
  mkdir -p "${squashfs_mount}"
  mount -t squashfs -o ro "${squashfs_path}" "${squashfs_mount}"

  info "Copying filesystem (this may take a while)..."
  rsync -aHAXx --info=progress2 \
    --exclude='/boot/efi/*' \
    --exclude='/tmp/*' \
    --exclude='/var/tmp/*' \
    --exclude='/var/cache/apt/archives/*.deb' \
    --exclude='/var/log/*' \
    --exclude='/swapfile' \
    "${squashfs_mount}/" "${INSTALL_POINT}/"

  info "Unmounting squashfs..."
  umount "${squashfs_mount}"
  rmdir "${squashfs_mount}"

  # Create the necessary directories
  mkdir -p "${INSTALL_POINT}/boot/efi"
  mkdir -p "${INSTALL_POINT}/tmp"
  mkdir -p "${INSTALL_POINT}/var/tmp"
  mkdir -p "${INSTALL_POINT}/var/log"
  chmod 1777 "${INSTALL_POINT}/tmp"
  chmod 1777 "${INSTALL_POINT}/var/tmp"

  info "System copy complete."
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
#   hostname_target, username, part_efi, part_boot, part_swap
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
USERID="__USERID__"
PART_EFI="__PART_EFI__"
PART_BOOT="__PART_BOOT__"
PART_SWAP="__PART_SWAP__"
FALLBACK_LOCALE="__FALLBACK_LOCALE__"
FALLBACK_TIMEZONE="__FALLBACK_TIMEZONE__"

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

  # Set locale using fallback
  locale-gen "${FALLBACK_LOCALE}"
  update-locale LANG="${FALLBACK_LOCALE}"

  # Set timezone using fallback
  ln -sf "/usr/share/zoneinfo/${FALLBACK_TIMEZONE}" /etc/localtime
  echo "${FALLBACK_TIMEZONE}" > /etc/timezone

  info "Locale set to: ${FALLBACK_LOCALE}"
  info "Timezone set to: ${FALLBACK_TIMEZONE}"
}

#######################################
# Create fstab entries
#######################################
create_fstab() {
  step "Creating /etc/fstab"

  local efi_uuid
  local boot_uuid
  local swap_uuid

  efi_uuid=$(blkid -s UUID -o value "${PART_EFI}")
  boot_uuid=$(blkid -s UUID -o value "${PART_BOOT}")
  swap_uuid=$(blkid -s UUID -o value "${PART_SWAP}")

  cat > /etc/fstab <<EOF
# <file system>                           <mount point>  <type>  <options>                    <dump> <pass>
# Boot partition
UUID=${boot_uuid}                         /boot          ext4    defaults,nofail              0      2
# EFI System Partition
UUID=${efi_uuid}                          /boot/efi      vfat    umask=0077,nofail            0      1
# Swap
UUID=${swap_uuid}                         none           swap    sw,discard                   0      0
EOF
}

#######################################
# Install ZFS boot support
#######################################
install_zfs_boot() {
  step "Installing ZFS boot support"

  apt-get update

  # Install zfs-initramfs for ZFS root boot support
  apt-get install -y zfs-initramfs
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

  local swap_uuid
  swap_uuid=$(blkid -s UUID -o value "${PART_SWAP}")

  # Update GRUB configuration
  cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Kubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="root=ZFS=System/Root resume=UUID=${swap_uuid}"
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
# Configure hibernation support
#######################################
configure_hibernation() {
  step "Configuring hibernation support"

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
# Create user account
#######################################
create_user() {
  step "Creating user account: ${USERNAME} (UID: ${USERID})"

  # Create user with specific UID
  useradd -m -s /bin/bash -u "${USERID}" -G adm,cdrom,sudo,dip,plugdev "${USERNAME}"

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
  create_fstab
  install_zfs_boot
  configure_kernel
  configure_grub
  configure_packages
  configure_hibernation
  create_user

  info "Chroot configurations complete!"
}

main "$@"
CHROOT_SCRIPT

  # Replace placeholders with actual values
  sed -i "s|__HOSTNAME__|${hostname_target}|g" "${script_path}"
  sed -i "s|__USERNAME__|${username}|g" "${script_path}"
  sed -i "s|__USERID__|${DEFAULT_USERID}|g" "${script_path}"
  sed -i "s|__PART_EFI__|${part_efi}|g" "${script_path}"
  sed -i "s|__PART_BOOT__|${part_boot}|g" "${script_path}"
  sed -i "s|__PART_SWAP__|${part_swap}|g" "${script_path}"
  sed -i "s|__FALLBACK_LOCALE__|${FALLBACK_LOCALE}|g" "${script_path}"
  sed -i "s|__FALLBACK_TIMEZONE__|${FALLBACK_TIMEZONE}|g" "${script_path}"

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
#   INSTALL_POINT, POOL_NAME
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

  info "Cleanup complete."
}

#######################################
# Parse command line arguments.
# Globals:
#   hostname_target, username, interactive
# Arguments:
#   Command line arguments
# Returns:
#   0 on success
#######################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--hostname)
        hostname_target="$2"
        shift 2
        ;;
      -u|--user)
        username="$2"
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
# Set default values for unset variables.
# Globals:
#   hostname_target, username
# Arguments:
#   None
# Returns:
#   0 on success
#######################################
set_defaults() {
  # Use defaults if not set via command line
  if [[ -z "${hostname_target}" ]]; then
    hostname_target="${DEFAULT_HOST}"
  fi

  if [[ -z "${username}" ]]; then
    username="${DEFAULT_USERNAME}"
  fi
}

#######################################
# Validate that all required disks exist.
# Globals:
#   DISK1, DISK2, DISK3
# Arguments:
#   None
# Returns:
#   0 if all disks exist, 1 otherwise
#######################################
validate_disks() {
  step "Validating target disks"

  local missing=0

  for disk in "${DISK1}" "${DISK2}" "${DISK3}"; do
    if [[ -b "${disk}" ]]; then
      info "Found: ${disk}"
    else
      err "Missing: ${disk}"
      missing=1
    fi
  done

  if [[ ${missing} -eq 1 ]]; then
    err "One or more target disks not found"
    return 1
  fi

  return 0
}

#######################################
# Display installation summary.
# Globals:
#   hostname_target, username, DISK1, DISK2, DISK3
# Arguments:
#   None
# Outputs:
#   Writes summary to stdout
#######################################
display_summary() {
  echo ""
  echo "============================================"
  echo "  Kubuntu RAIDZ Installation Summary"
  echo "============================================"
  echo "  Hostname:       ${hostname_target}"
  echo "  Username:       ${username}"
  echo "  User ID:        ${DEFAULT_USERID}"
  echo ""
  echo "  Target Disks (RAIDZ1):"
  echo "    - ${DISK1}"
  echo "    - ${DISK2}"
  echo "    - ${DISK3}"
  echo ""
  echo "  Partition Sizes:"
  echo "    - EFI:  ${EFI_SIZE}"
  echo "    - Boot: ${BOOT_SIZE}"
  echo "    - Swap: ${SWAP_SIZE}"
  echo ""
  echo "  ZFS Pool:       ${POOL_NAME} (RAIDZ1)"
  echo "============================================"
  echo ""
  warn "WARNING: ALL DATA ON ALL THREE DISKS WILL BE DESTROYED!"
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
  echo "║  Kubuntu 24.10 Installation with ZFS RAIDZ (No Encryption) ║"
  echo "║  Version: ${SCRIPT_VERSION}                                         ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  #######################################
  # Global variables (set during runtime)
  #######################################
  hostname_target=""
  username=""
  interactive=true

  # Partition variables (populated after partitioning)
  part_efi=""
  part_boot=""
  part_swap=""
  part_data1=""
  part_data2=""
  part_data3=""

  # Squashfs path (populated by find_squashfs)
  squashfs_path=""

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

  set_defaults
  validate_disks || exit 1

  display_summary

  if ! confirm "Proceed with installation?"; then
    info "Installation cancelled by user."
    exit 0
  fi

  # Find squashfs before proceeding
  find_squashfs || exit 1

  # Set up a trap for cleanup on error
  trap cleanup EXIT

  install_live_packages
  partition_disks
  create_zfs_pool
  setup_boot_partitions
  copy_system_from_squashfs
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
