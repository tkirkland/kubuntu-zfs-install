# Kubuntu ZFS RAIDZ1 Installation Script

Automated installation script for Kubuntu 25.10 (Questing Quokka) on a 3-disk ZFS RAIDZ1 configuration.

## Features

- **ZFS Root**: RAIDZ1 pool across 3 NVMe drives with all features enabled
- **Redundant Boot**: mdadm RAID1 mirrors for EFI and /boot partitions
- **Fast Swap**: mdadm RAID0 stripe across all 3 disks
- **Secure Boot**: Automatic MOK key generation for DKMS module signing
- **Clean Install**: Removes snaps, LibreOffice, and other bloatware
- **Hibernation Ready**: Swap configured with resume support

## Disk Layout

| Partition | Type | Size | Filesystem |
|-----------|------|------|------------|
| EFI | mdadm RAID1 (disk1 + disk2) | 512MB | FAT32 |
| Boot | mdadm RAID1 (disk1 + disk2) | 2GB | ext4 |
| Swap | mdadm RAID0 (all 3 disks) | 12GB | swap |
| Root | ZFS RAIDZ1 (all 3 disks) | Remainder | ZFS |

## ZFS Dataset Structure

```
${POOLNAME}
├── ROOT/kubuntu    (mountpoint=/)
├── home            (mountpoint=/home)
├── var/cache       (mountpoint=/var/cache)
├── var/log         (mountpoint=/var/log)
└── var/tmp         (mountpoint=/var/tmp)
```

## Requirements

- Kubuntu 25.10 live USB
- 3 NVMe drives (paths hardcoded in script)
- Network connectivity
- UEFI boot mode

## Usage

1. Boot into Kubuntu 25.10 live environment ("Try Kubuntu")
2. Edit the script to set your disk paths (`disk1`, `disk2`, `disk3`)
3. Run as root:

```bash
sudo ./kubuntu_zfs_install.sh
```

4. On first reboot with Secure Boot enabled, enroll the MOK key when prompted

## Configuration

Edit these variables in the script before running:

```bash
disk1="/dev/disk/by-id/nvme-..."
disk2="/dev/disk/by-id/nvme-..."
disk3="/dev/disk/by-id/nvme-..."
HOSTNAME="your-hostname"
username="your-username"
```

## What Gets Installed

- Base Kubuntu system extracted from squashfs
- ZFS utilities and kernel modules
- GRUB with ZFS support
- NetworkManager
- Brave browser
- NVIDIA drivers (if hardware detected)
- Secure Boot MOK key for module signing

## What Gets Removed

- Snapd and all snap packages
- LibreOffice suite
- Calamares installer
- Live session packages
- KDE welcome screen

## License

MIT
