#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

#######################################
# Cleanup script for ZFS pools and mdadm arrays.
# Stops services, unmounts filesystems, destroys pool and arrays.
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

poolname="${1:-System}"
install_root="${2:-/mnt/install}"

info "Unmounting chroot bind mounts..."
for mnt in "$install_root/dev" "$install_root/proc" "$install_root/sys"; do
  if mountpoint -q "$mnt" 2>/dev/null; then
    info "Unmounting $mnt (recursive)"
    umount -R "$mnt" || {
      error "Failed to unmount $mnt"
      fuser -vm "$mnt" 2>/dev/null || true
      exit 1
    }
  fi
done

info "Unmounting boot partitions..."
for mnt in "$install_root/boot/efi" "$install_root/boot"; do
  if mountpoint -q "$mnt" 2>/dev/null; then
    info "Unmounting $mnt"
    umount "$mnt" || {
      error "Failed to unmount $mnt"
      fuser -vm "$mnt" 2>/dev/null || true
      exit 1
    }
  fi
done

info "Stopping ZFS services..."
systemctl stop zfs-zed.service 2>/dev/null || true
systemctl stop zfs-mount.service 2>/dev/null || true
systemctl stop zfs-share.service 2>/dev/null || true
systemctl stop zfs.target 2>/dev/null || true
systemctl stop zfs-import.target 2>/dev/null || true
systemctl stop zfs-import-cache.service 2>/dev/null || true

info "Unmounting ZFS filesystems..."
zfs list -H -o name,mountpoint -r "$poolname" 2>/dev/null | sort -r -k2 | while read -r dataset mountpoint; do
  if [[ "$mountpoint" != "-" && "$mountpoint" != "none" ]]; then
    info "Unmounting $dataset ($mountpoint)"
    zfs unmount "$dataset" 2>/dev/null || umount "$mountpoint" 2>/dev/null || true
    # Verify unmount
    if mountpoint -q "$mountpoint" 2>/dev/null; then
      error "Failed to unmount $mountpoint"
      fuser -vm "$mountpoint" 2>/dev/null || true
      exit 1
    fi
  fi
done

# Verify no pool mounts remain
if mount | grep -q " $poolname"; then
  error "ZFS mounts still active:"
  mount | grep "$poolname"
  exit 1
fi

info "Exporting ZFS pool '$poolname'..."
if zpool list "$poolname" &>/dev/null; then
  zpool export "$poolname" || {
    error "Failed to export pool - checking for busy processes"
    fuser -vm /mnt 2>/dev/null || true
    exit 1
  }
  info "Pool '$poolname' exported"
else
  warn "Pool '$poolname' not found or already exported"
fi

info "Stopping mdadm arrays..."
for md in /dev/md/efi /dev/md/boot /dev/md/swap /dev/md127 /dev/md126 /dev/md125; do
  if [[ -e "$md" ]]; then
    info "Stopping $md"
    mdadm --stop "$md" 2>/dev/null || true
  fi
done

info "Removing mdadm arrays..."
for md in /dev/md/efi /dev/md/boot /dev/md/swap /dev/md127 /dev/md126 /dev/md125; do
  if [[ -e "$md" ]]; then
    info "Removing $md"
    mdadm --remove "$md" 2>/dev/null || true
  fi
done

info "Zeroing mdadm superblocks on partitions..."
for disk in /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1; do
  for part in 1 2 3; do
    if [[ -e "${disk}p${part}" ]]; then
      info "Zeroing superblock on ${disk}p${part}"
      mdadm --zero-superblock "${disk}p${part}" 2>/dev/null || true
    fi
  done
done

info "Cleanup complete."
