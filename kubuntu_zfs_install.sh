#!/bin/bash
#
# Kubuntu 25.10 (Questing Quokka) ZFS RAIDZ1 Installation Script
#
# This script installs Kubuntu 25.10 on a 3-disk RAIDZ1 configuration with:
#   - EFI:  mdadm RAID1 mirror (disk1-part1 + disk2-part1) - FAT32
#   - Boot: mdadm RAID1 mirror (disk1-part2 + disk2-part2) - ext4
#   - Swap: mdadm RAID0 (disk1-part3 + disk2-part3 + disk3-part1)
#   - ZFS:  RAIDZ1 (disk1-part4 + disk2-part4 + disk3-part2) - all features enabled
#
# Run from the Kubuntu 25.10 live environment with the "Try Kubuntu" option.
#

set -euo pipefail

#------------------------------------------------------------------------------
# Color output helpers
#------------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

readonly disk1="/dev/disk/by-id/nvme-eui.0025384331408197"
readonly disk2="/dev/disk/by-id/nvme-eui.002538433140818a"
readonly disk3="/dev/disk/by-id/nvme-eui.002538433140819d"

# bashsupport disable=BP5008,BP5001
{
  info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
  success() { echo -e "${GREEN}[OK]${NC} $*"; }
  warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
  error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
  fatal()   { error "$*" ; exit 1; }
}
#------------------------------------------------------------------------------
# Global variables
#------------------------------------------------------------------------------
readonly install_root="/mnt/install"

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------
preflight_checks() {
    info "Running pre-flight checks..."

    local cmd
    # Must be root
    [[ $EUID -eq 0 ]] || fatal "This script must be run as root. Use: sudo $0"

    # Check for live environment
    if [[ ! -d /cdrom ]] && [[ ! -d /run/live ]]; then
        warn "This doesn't appear to be a live environment. Proceed with caution."
  fi

    # Locate squashfs
    if [[ -f /cdrom/casper/filesystem.squashfs ]]; then
        squashfs_path="/cdrom/casper/filesystem.squashfs"
  elif   [[ -f /run/live/medium/casper/filesystem.squashfs ]]; then
        squashfs_path="/run/live/medium/casper/filesystem.squashfs"
  else
        fatal "Cannot locate filesystem.squashfs. Are you running from a Kubuntu live environment?"
  fi
    info "Found squashfs: $squashfs_path"

    # Check network connectivity
    if ! ping -c 1 -W 3 archive.ubuntu.com &> /dev/null; then
        fatal "No network connectivity. Please connect to the internet first."
  fi

    # Check for required commands
    for cmd in sgdisk mdadm unsquashfs chroot zpool zfs; do
        command -v "$cmd" &> /dev/null || fatal "Required command '$cmd' not found."
  done

    # Check and clean up existing md arrays
    local array member
    if [[ -f /proc/mdstat ]]; then
        while read -r array; do
            if [[ -n $array ]]; then
                warn "Found existing md array: $array"

                # Unmount any filesystems on this array first
                if mount | grep -q "/dev/$array"; then
                    info "Unmounting filesystems on /dev/$array..."
                    umount "/dev/$array" 2>/dev/null || true
        fi

                # Get member devices before stopping
                local members
                members=$(mdadm --detail "/dev/$array" 2> /dev/null |
                  awk '/\/dev\// && !/\/dev\/md/ {print $NF}' || true)

                # Stop the array
                mdadm --stop "/dev/$array" || warn "Failed to stop $array"
                mdadm --remove "/dev/$array" 2> /dev/null || true

                # Zero superblocks on member devices
                for member in $members; do
                    if [[ -b $member   ]]; then
                        info "Zeroing superblock on $member..."
                        mdadm --zero-superblock "$member" 2> /dev/null || true
          fi
        done
      fi
    done     < <(awk '/^md/ {print $1}' /proc/mdstat)
  fi

    success "Pre-flight checks passed."
}

#------------------------------------------------------------------------------
# Install required packages in live environment
#------------------------------------------------------------------------------
install_live_packages() {
    info "Installing required packages in live environment..."
    apt-get update -qq
    apt-get install -y gdisk mdadm zfsutils-linux squashfs-tools
    success "Live environment packages installed."
}

#------------------------------------------------------------------------------
# Prompt for disk selection
#------------------------------------------------------------------------------
select_disks() {
    # Validate disks exist
    for disk in "$disk1" "$disk2" "$disk3"; do
        [[ -b $disk   ]] || fatal "Disk not found: $disk"
  done

    # Ensure all disks are different
    if [[ $disk1 == "$disk2"   ]] || [[ $disk1 == "$disk3"   ]] \
      || [[ $disk2 == "$disk3"   ]]; then
        fatal "All three disks must be different."
  fi

    info "Selected disks:"
    echo "  Disk 1: $disk1"
    echo "  Disk 2: $disk2"
    echo "  Disk 3: $disk3"
}

#------------------------------------------------------------------------------
# Prompt for system configuration
#------------------------------------------------------------------------------
get_system_config() {
    HOSTNAME="PRECISION"
    username="me"

    # Pool name defaults to hostname
    poolname="${HOSTNAME}"

    info "System configuration:"
    echo "  Hostname:  $HOSTNAME"
    echo "  Username:  $username"
    echo "  Pool name: $poolname"
}

#------------------------------------------------------------------------------
# Wipe and partition disks
#------------------------------------------------------------------------------
partition_disks() {
    info "Wiping and partitioning disks..."

    # Wipe all disks
    for disk in "$disk1" "$disk2" "$disk3"; do
        info "Wiping $disk..."
        wipefs -af "$disk" 2> /dev/null || true
        sgdisk --zap-all "$disk"
        blkdiscard -f "$disk" 2> /dev/null || true
  done

    # Partition Disk 1: EFI (512MB) + Boot (2GB) + Swap (4GB) + ZFS (remainder)
    info "Partitioning Disk 1..."
    sgdisk -n1:1M:+512M -t1:EF00 -c1:EFI1  "$disk1"
    sgdisk -n2:0:+2G    -t2:FD00 -c2:BOOT1 "$disk1"
    sgdisk -n3:0:+4G    -t3:FD00 -c3:SWAP1 "$disk1"
    sgdisk -n4:0:0      -t4:BF00 -c4:ZFS1  "$disk1"

    # Partition Disk 2: EFI (512MB) + Boot (2GB) + Swap (4GB) + ZFS (remainder)
    info "Partitioning Disk 2..."
    sgdisk -n1:1M:+512M -t1:EF00 -c1:EFI2  "$disk2"
    sgdisk -n2:0:+2G    -t2:FD00 -c2:BOOT2 "$disk2"
    sgdisk -n3:0:+4G    -t3:FD00 -c3:SWAP2 "$disk2"
    sgdisk -n4:0:0      -t4:BF00 -c4:ZFS2  "$disk2"

    # Partition Disk 3: Swap (4GB) + ZFS (remainder)
    info "Partitioning Disk 3..."
    sgdisk -n1:1M:+4G   -t1:FD00 -c1:SWAP3 "$disk3"
    sgdisk -n2:0:0      -t2:BF00 -c2:ZFS3  "$disk3"

    # Wait for partition devices to appear
    sleep 2
    partprobe "$disk1" "$disk2" "$disk3"
    sleep 2

    success "Disk partitioning complete."
}

#------------------------------------------------------------------------------
# Create mdadm RAID arrays
#------------------------------------------------------------------------------
create_mdadm_arrays() {
    info "Creating mdadm RAID arrays..."

    # Stop any existing arrays
    mdadm --stop /dev/md/efi  2> /dev/null || true
    mdadm --stop /dev/md/boot 2> /dev/null || true
    mdadm --stop /dev/md/swap 2> /dev/null || true
    mdadm --stop /dev/md0 2> /dev/null || true
    mdadm --stop /dev/md1 2> /dev/null || true
    mdadm --stop /dev/md2 2> /dev/null || true

    # Create EFI mirror (RAID1) - metadata 1.0 for EFI compatibility
    info "Creating EFI RAID1 mirror..."
    mdadm --create /dev/md/efi \
        --level=1 \
        --raid-devices=2 \
        --metadata=1.0 \
        --bitmap=internal \
        --homehost=any \
        --name=efi \
        --run \
        "${disk1}-part1" "${disk2}-part1"

    # Create Boot mirror (RAID1) - metadata 1.0 for GRUB compatibility
    info "Creating Boot RAID1 mirror..."
    mdadm --create /dev/md/boot \
        --level=1 \
        --raid-devices=2 \
        --metadata=1.0 \
        --bitmap=internal \
        --homehost=any \
        --name=boot \
        --run \
        "${disk1}-part2" "${disk2}-part2"

    # Create Swap striped array (RAID0) - no bitmap for RAID0
    info "Creating Swap RAID0 array..."
    mdadm --create /dev/md/swap \
        --level=0 \
        --raid-devices=3 \
        --metadata=1.2 \
        --homehost=any \
        --name=swap \
        --run \
        "${disk1}-part3" "${disk2}-part3" "${disk3}-part1"

    # Wait for arrays to initialize
    sleep 2

    success "mdadm RAID arrays created."
}

#------------------------------------------------------------------------------
# Format EFI, Boot, and Swap
#------------------------------------------------------------------------------
format_partitions() {
    info "Formatting EFI, Boot, and Swap partitions..."

    # Format EFI as FAT32
    mkfs.vfat -F 32 -n EFI /dev/md/efi

    # Format Boot as ext4
    mkfs.ext4 -L boot /dev/md/boot

    # Format Swap
    mkswap -L swap /dev/md/swap

    success "EFI, Boot, and Swap formatted."
}

#------------------------------------------------------------------------------
# Create ZFS pool
#------------------------------------------------------------------------------
create_zfs_pool() {
    info "Creating ZFS pool..."

    # Generate hostid for the live environment - pool will be stamped with this
    # We'll copy it to the installed system after squashfs extraction
    zgenhostid -f

    # Destroy the existing pool if present
    zpool destroy "$poolname" 2> /dev/null || true

    # Create a RAIDZ1 pool with all features enabled
    # No compatibility restriction needed since /boot is on ext4
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O compression=zstd \
        -O normalization=formD \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=none \
        -R "$install_root" \
        "$poolname" \
        raidz1 \
        "${disk1}-part4" "${disk2}-part4" "${disk3}-part2"

    success "ZFS pool '$poolname' created with all features enabled."
}

#------------------------------------------------------------------------------
# Create ZFS datasets
#------------------------------------------------------------------------------
create_zfs_datasets() {
    info "Creating ZFS datasets..."

    # ROOT container (for boot environments)
    zfs create -o canmount=off -o mountpoint=none "$poolname/ROOT"

    # Root filesystem
    zfs create -o canmount=noauto -o mountpoint=/ "$poolname/ROOT/kubuntu"
    zfs mount "$poolname/ROOT/kubuntu"

    # Home dataset
    zfs create -o mountpoint=/home "$poolname/home"

    # Var container
    zfs create -o canmount=off -o mountpoint=none "$poolname/var"

    # Var subdatasets
    zfs create -o mountpoint=/var/log "$poolname/var/log"
    zfs create -o mountpoint=/var/cache -o "com.sun:auto-snapshot=false"\
      "$poolname/var/cache"
    zfs create -o mountpoint=/var/tmp -o "com.sun:auto-snapshot=false"\
      "$poolname/var/tmp"

    # Srv dataset
    zfs create -o mountpoint=/srv "$poolname/srv"

    success "ZFS datasets created."
}

#------------------------------------------------------------------------------
# Mount additional filesystems
#------------------------------------------------------------------------------
mount_filesystems() {
    info "Mounting additional filesystems..."

    # Create and mount the boot directory
    mkdir -p "$install_root/boot"
    mount /dev/md/boot "$install_root/boot"

    # Create and mount the EFI directory
    mkdir -p "$install_root/boot/efi"
    mount /dev/md/efi "$install_root/boot/efi"

    success "Filesystems mounted."
}

#------------------------------------------------------------------------------
# Extract squashfs to target
#------------------------------------------------------------------------------
extract_squashfs() {
    info "Extracting squashfs to target (this will take a while)..."

    unsquashfs -f -d "$install_root" "$squashfs_path"

    # Copy hostid from live environment to installed system
    # The pool was created with this hostid, so they must match
    info "Copying hostid for ZFS pool import..."
    cp /etc/hostid "$install_root/etc/hostid"

    success "Squashfs extraction complete."
}

#------------------------------------------------------------------------------
# Install kernel from live environment
#------------------------------------------------------------------------------
install_kernel() {
    info "Installing kernel from live environment..."

    # Get kernel version from modules directory
    local kernel_version
    kernel_version=$(find "$install_root/usr/lib/modules/" -mindepth 1 \
      -maxdepth 1 -type d -printf '%f\n' | head -1)

    if [[ -z $kernel_version   ]]; then
        fatal "Could not determine kernel version from modules directory"
  fi

    info "Detected kernel version: $kernel_version"

    # Copy kernel from the casper directory
    cp /cdrom/casper/vmlinuz "$install_root/boot/vmlinuz-$kernel_version"

    # Update symlinks
    ln -sf "vmlinuz-$kernel_version" "$install_root/boot/vmlinuz"
    ln -sf "vmlinuz-$kernel_version" "$install_root/boot/vmlinuz.old"

    success "Kernel installed: vmlinuz-$kernel_version"
}

#------------------------------------------------------------------------------
# Configure the new system
#------------------------------------------------------------------------------
configure_system() {
    info "Configuring the new system..."

    # Set hostname
    echo "$HOSTNAME" > "$install_root/etc/hostname"
    cat > "$install_root/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

# IPv6
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # Copy network configuration
    mkdir -p "$install_root/etc/netplan"
    cp /etc/netplan/*.yaml "$install_root/etc/netplan/" 2> /dev/null || true

    # Configure apt sources for Questing Quokka
    cat > "$install_root/etc/apt/sources.list.d/kubuntu.sources" << EOF
Types: deb
URIs: https://archive.ubuntu.com/ubuntu
Suites: questing questing-updates questing-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://security.ubuntu.com/ubuntu
Suites: questing-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    # Remove old sources.list if exists
    rm -f "$install_root/etc/apt/sources.list"

    success "System configuration complete."
}

#------------------------------------------------------------------------------
# Chroot setup and installation
#------------------------------------------------------------------------------
chroot_install() {
    info "Setting up chroot environment..."

    # Mount virtual filesystems with rslave for clean unmount
    mount --rbind /dev  "$install_root/dev"
    mount --make-rslave "$install_root/dev"
    mount --rbind /proc "$install_root/proc"
    mount --make-rslave "$install_root/proc"
    mount --rbind /sys  "$install_root/sys"
    mount --make-rslave "$install_root/sys"

    # Copy resolv.conf for network access in chroot
    cp /etc/resolv.conf "$install_root/etc/resolv.conf"

    # Create the chroot script
    cat > "$install_root/tmp/chroot-install.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export POOLNAME="@@POOLNAME@@"
export USERNAME="@@USERNAME@@"

echo "[INFO] Configuring locale and timezone..."
locale-gen --purge "en_US.UTF-8"
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Set hardware clock to local time (timedatectl doesn't work in chroot)
cat > /etc/adjtime <<ADJTIME
0.0 0 0.0
0
LOCAL
ADJTIME

echo "[INFO] Regenerating machine-id..."
systemd-machine-id-setup

echo "[INFO] Updating package lists..."
apt-get -qq update

echo "[INFO] Deferring update-grub during package installation..."
# Divert update-grub to prevent ANY invocation during package installs
# This catches direct postinst calls, triggers, and hook scripts
dpkg-divert --local --rename --divert /usr/sbin/update-grub.real --add /usr/sbin/update-grub
ln -sf /bin/true /usr/sbin/update-grub

echo "[INFO] Installing/updating ZFS packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    zfs-initramfs \
    zfsutils-linux \
    zfs-zed

echo "[INFO] Installing mdadm..."
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y mdadm

echo "[INFO] Configuring mdadm..."
# Ensure mdadm.conf directory exists
mkdir -p /etc/mdadm

# Create a clean mdadm.conf with proper array definitions
cat > /etc/mdadm/mdadm.conf <<MDADM_CONF
# mdadm.conf - Configuration for mdadm RAID arrays
# Auto-generated by ZFS installer

HOMEHOST <system>
MAILADDR root

# RAID array definitions
MDADM_CONF

# Append the actual array definitions
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

# Reconfigure mdadm to ensure arrays are in initramfs
dpkg-reconfigure -f noninteractive mdadm

# Ensure udev rules are updated for mdadm
udevadm control --reload-rules || true
udevadm trigger || true

# Verify arrays are assembled and symlinks exist
echo "[DEBUG] mdadm array status:"
mdadm --detail --scan
ls -la /dev/md/ || echo "[WARN] /dev/md/ directory not found"

echo "[INFO] Installing GRUB..."
# Install grub packages - update-grub calls are diverted to /bin/true
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed

echo "[INFO] Configuring fstab..."
# Get UUIDs for reliable boot - mdadm symlinks may not exist at early boot
BOOT_UUID=$(blkid -s UUID -o value /dev/md/boot)
EFI_UUID=$(blkid -s UUID -o value /dev/md/efi)
SWAP_UUID=$(blkid -s UUID -o value /dev/md/swap)

cat > /etc/fstab <<FSTAB
# /etc/fstab - static file system information
# Auto-generated by ZFS installer

# Boot partition (mdadm RAID1 + ext4)
UUID=${BOOT_UUID}  /boot       ext4   defaults,noatime,nofail,x-systemd.device-timeout=10s   0   1

# EFI partition (mdadm RAID1 + FAT32)
UUID=${EFI_UUID}   /boot/efi   vfat   defaults,noatime,nofail,x-systemd.device-timeout=10s,umask=0077   0   1

# Swap (mdadm RAID0)
UUID=${SWAP_UUID}  none        swap   sw,nofail,x-systemd.device-timeout=10s   0   0
FSTAB

echo "[INFO] Setting ZFS cachefile..."
mkdir -p /etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "$POOLNAME"

echo "[INFO] Configuring GRUB for ZFS root..."
# Set quiet splash and enable OS prober for dual-boot
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub

cat >> /etc/default/grub <<GRUBCFG

# ZFS root filesystem
GRUB_CMDLINE_LINUX="root=ZFS=$POOLNAME/ROOT/kubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"

# Enable OS prober to detect other operating systems
GRUB_DISABLE_OS_PROBER=false

# Screen resolution (16:9)
GRUB_GFXMODE=1600x900
GRUBCFG

echo "[INFO] Ensuring mdadm is included in initramfs..."
# Make sure initramfs include mdadm modules
cat > /etc/initramfs-tools/conf.d/mdadm <<MDADM_INITRAMFS
# Include mdadm in initramfs for boot partition assembly
BOOT_DEGRADED=true
MDADM_INITRAMFS

# Update initramfs with mdadm and ZFS support
echo "[INFO] Updating initramfs..."
update-initramfs -c -k all

echo "[INFO] Restoring update-grub..."
rm -f /usr/sbin/update-grub
dpkg-divert --rename --remove /usr/sbin/update-grub

echo "[INFO] Installing GRUB to EFI..."
# Use --no-nvram since we're in a chroot and can't write EFI variables
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=kubuntu --recheck --no-nvram

echo "[INFO] Updating GRUB configuration..."
update-grub

echo "[INFO] Registering EFI boot entry..."
# Create EFI boot entry using actual disk (not md device - EFI doesn't understand mdadm)
# Use disk1 partition 1 (first member of EFI mirror)
efibootmgr --create --disk @@DISK1@@ --part 1 --label "Kubuntu" --loader "\\EFI\\kubuntu\\shimx64.efi" 2>/dev/null || \
    echo "[WARN] Could not register EFI boot entry - may need to do this after reboot"

echo "[INFO] Removing snapd..."
# Unmount all snap mounts first
umount /snap/bare/* 2>/dev/null || true
umount /snap/core*/* 2>/dev/null || true
umount /snap/snapd/* 2>/dev/null || true
umount /snap/* 2>/dev/null || true
umount /var/lib/snapd/snap/* 2>/dev/null || true

# Remove all snap files before purging
rm -rf /var/lib/snapd /var/snap /var/cache/snapd /snap /root/snap 2>/dev/null || true

# Neuter maintainer scripts to avoid systemd calls in chroot
for script in /var/lib/dpkg/info/snapd.{prerm,postrm}; do
    [[ -f "$script" ]] && echo "exit 0" > "$script"
done

# Now purge cleanly
dpkg --purge snapd 2>/dev/null || true
apt-get purge -qq -y --auto-remove snapd 2>/dev/null || true

# Block future installation
cat > /etc/apt/preferences.d/no-snapd <<SNAPD
Package: snapd
Pin: release *
Pin-Priority: -1
SNAPD

echo "[INFO] Removing live session packages..."
apt-get purge -qq -y \
    'live-*' \
    calamares-settings-kubuntu \
    calamares-settings-ubuntu-common \
    calamares-settings-ubuntu-common-data \
    calamares \
    kubuntu-installer-prompt \
    2>/dev/null || true

echo "[INFO] Removing LibreOffice..."
apt-get purge -qq -y 'libreoffice*' 2>/dev/null || true
apt-get autoremove -qq -y

echo "[INFO] Checking for NVIDIA GPU..."
if lspci -n | grep -q '10de:'; then
    echo "[INFO] NVIDIA GPU detected—installing drivers..."
    ubuntu-drivers install
else
    echo "[INFO] No NVIDIA GPU detected"
fi

echo "[INFO] Creating user '$USERNAME'..."
useradd -m -s /bin/bash -G adm,cdrom,sudo,dip,plugdev,lpadmin "$USERNAME"
echo "[INFO] Set password for $USERNAME:"
passwd "$USERNAME"

echo "[INFO] Configuring sudoers for common tasks..."
cat > /etc/sudoers.d/nopasswd-apps <<SUDOERS
# Allow users in sudo group to run package management without password
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt-get
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt-cache
%sudo ALL=(ALL) NOPASSWD: /usr/bin/dpkg
%sudo ALL=(ALL) NOPASSWD: /usr/bin/flatpak
%sudo ALL=(ALL) NOPASSWD: /usr/bin/discover
%sudo ALL=(ALL) NOPASSWD: /usr/bin/plasma-discover
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl
%sudo ALL=(ALL) NOPASSWD: /usr/bin/journalctl
# ZFS tools
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/zpool
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/zfs
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/zdb
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/zed
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/zstreamdump
SUDOERS
chmod 440 /etc/sudoers.d/nopasswd-apps

echo "[INFO] Configuring Polkit for packagekit/flatpak..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-nopasswd-packagekit.rules <<POLKIT
// Allow user to install/update packages without password
polkit.addRule(function(action, subject) {
    if ((action.id.indexOf("org.freedesktop.packagekit.") === 0 ||
         action.id.indexOf("org.freedesktop.Flatpak.") === 0) &&
        subject.user === "$USERNAME") {
        return polkit.Result.YES;
    }
});
POLKIT

echo "[INFO] Enabling ZFS services..."
systemctl enable zfs-import-cache.service
systemctl enable zfs-import.target
systemctl enable zfs-mount.service
systemctl enable zfs.target

echo "[INFO] Chroot installation complete."
CHROOT_SCRIPT

    # Substitute variables in the chroot script
    sed -i "s/@@POOLNAME@@/$poolname/g" "$install_root/tmp/chroot-install.sh"
    sed -i "s/@@USERNAME@@/$username/g" "$install_root/tmp/chroot-install.sh"
    sed -i "s|@@DISK1@@|$disk1|g" "$install_root/tmp/chroot-install.sh"

    chmod +x "$install_root/tmp/chroot-install.sh"
    chroot "$install_root" /tmp/chroot-install.sh

    # Clean up
    rm -f "$install_root/tmp/chroot-install.sh"

    success "Chroot installation complete."
}

#------------------------------------------------------------------------------
# Cleanup and prepare for reboot
#------------------------------------------------------------------------------
final_cleanup() {
    info "Final cleanup..."

    # Unmount in the correct order - most nested first, no lazy unmounts
    # First unmount nested virtual filesystems
    umount "$install_root/proc/sys/fs/binfmt_misc" 2>/dev/null || true
    umount "$install_root/dev/pts" 2>/dev/null || true
    umount "$install_root/dev/shm" 2>/dev/null || true
    umount "$install_root/dev/hugepages" 2>/dev/null || true
    umount "$install_root/dev/mqueue" 2>/dev/null || true
    umount "$install_root/sys/kernel/security" 2>/dev/null || true
    umount "$install_root/sys/fs/cgroup" 2>/dev/null || true

    # Then unmount main virtual filesystems
    umount "$install_root/dev" 2>/dev/null || true
    umount "$install_root/proc" 2>/dev/null || true
    umount "$install_root/sys" 2>/dev/null || true
    umount "$install_root/run" 2>/dev/null || true

    # Unmount EFI and Boot
    umount "$install_root/boot/efi" 2>/dev/null || true
    umount "$install_root/boot" 2>/dev/null || true

    # Unmount any remaining ZFS datasets
    zfs unmount -a 2>/dev/null || true

    # Export ZFS pool
    zpool export "$poolname"

    # Stop mdadm arrays
    mdadm --stop /dev/md/efi 2>/dev/null || true
    mdadm --stop /dev/md/boot 2>/dev/null || true
    mdadm --stop /dev/md/swap 2>/dev/null || true

    success "Cleanup complete."
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    echo ""
    echo "========================================"
    echo " Kubuntu 25.10 ZFS RAIDZ1 Installer"
    echo " (Questing Quokka)"
    echo "========================================"
    echo ""

    squashfs_path=""
    preflight_checks
    install_live_packages
    select_disks
    get_system_config
    partition_disks
    create_mdadm_arrays
    format_partitions
    create_zfs_pool
    create_zfs_datasets
    mount_filesystems
    extract_squashfs
    install_kernel
    configure_system
    chroot_install
    final_cleanup

    echo ""
    success "========================================"
    success " Installation Complete!"
    success "========================================"
    echo ""
    info "You can now reboot into your new system."
    info "Run: reboot"
    echo ""
}

main "$@"
