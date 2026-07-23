#!/bin/bash

set -euo pipefail

# 0700 Microsoft basic data  0c01 Microsoft reserved    2700 Windows RE          
# 4100 PowerPC PReP boot     4200 Windows LDM data      4201 Windows LDM metadata
# 7501 IBM GPFS              7f00 ChromeOS kernel       7f01 ChromeOS root       
# 7f02 ChromeOS reserved     8200 Linux swap            8300 Linux filesystem    
# 8301 Linux reserved        8302 Linux /home           8400 Intel Rapid Start   
# 8e00 Linux LVM             a500 FreeBSD disklabel     a501 FreeBSD boot        
# a502 FreeBSD swap          a503 FreeBSD UFS           a504 FreeBSD ZFS         
# a505 FreeBSD Vinum/RAID    a580 Midnight BSD data     a581 Midnight BSD boot   
# a582 Midnight BSD swap     a583 Midnight BSD UFS      a584 Midnight BSD ZFS    
# a585 Midnight BSD Vinum    a800 Apple UFS             a901 NetBSD swap         
# a902 NetBSD FFS            a903 NetBSD LFS            a904 NetBSD concatenated 
# a905 NetBSD encrypted      a906 NetBSD RAID           ab00 Apple boot          
# af00 Apple HFS/HFS+        af01 Apple RAID            af02 Apple RAID offline  
# af03 Apple label           af04 AppleTV recovery      af05 Apple Core Storage  
# be00 Solaris boot          bf00 Solaris root          bf01 Solaris /usr & Mac Z
# bf02 Solaris swap          bf03 Solaris backup        bf04 Solaris /var        
# bf05 Solaris /home         bf06 Solaris alternate se  bf07 Solaris Reserved 1  
# bf08 Solaris Reserved 2    bf09 Solaris Reserved 3    bf0a Solaris Reserved 4  
# bf0b Solaris Reserved 5    c001 HP-UX data            c002 HP-UX service       
# ea00 Freedesktop $BOOT     eb00 Haiku BFS             ed00 Sony system partitio
# ef00 EFI System            ef01 MBR partition scheme  ef02 BIOS boot partition 
# Press the  key to see more codes:  
# fb00 VMWare VMFS           fb01 VMWare reserved       fc00 VMWare kcore crash p
# fd00 Linux RAID            


# ==============================================================================
# Configuration
# ==============================================================================
TARGET_DISK="${1:-/dev/nvme0n1}"
IMAGE_REF="${2:-tharsis:latest}"
MOUNT_DIR="/mnt"

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." >&2
   exit 1
fi

echo "==> Preparing installation on ${TARGET_DISK} using image ${IMAGE_REF}..."

# Standardize partition suffix for loop/nvme vs sd/vd devices
if [[ "${TARGET_DISK}" =~ [0-9]$ ]]; then
    PART_PREFIX="${TARGET_DISK}p"
else
    PART_PREFIX="${TARGET_DISK}"
fi

PART_EFI="${PART_PREFIX}1"
PART_BOOT="${PART_PREFIX}2"
PART_ROOT="${PART_PREFIX}3"
PART_SYSROOT="${PART_PREFIX}4"

# ==============================================================================
# 1. Disk Partitioning (GPT)
# ==============================================================================
echo "==> Wiping and partitioning disk ${TARGET_DISK}..."
wipefs -a -f "${TARGET_DISK}"
sgdisk --zap-all "${TARGET_DISK}"

# Create GPT Partitions:
# 1: EFI System Partition (512M) - Type C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# 2: /boot Partition (1024M)     - Type BC13C2FF-59E6-4262-A352-B275FD6F7172 (XBOOTLDR/Boot)
# 3: Root Partition (20G)       - Type 4F688204-4011-4F12-9A6C-2D54177E25C7 (Linux Root x86-64)
# 3: Root Partition (Rest)       - Type 4F688204-4011-4F12-9A6C-2D54177E25C7 (Linux Root x86-64)
sgdisk -n 1:0:+512M     -t 1:ef00   -c 1:"EFI System Partition"   "${TARGET_DISK}"
sgdisk -n 2:0:+1024M    -t 2:ea00   -c 2:"Boot Partition"         "${TARGET_DISK}"
sgdisk -n 3:0:+20G      -t 3:8304   -c 3:"Root Partition"         "${TARGET_DISK}"
sgdisk -n 4:0:0         -t 3:8300   -c 4:"Sysroot Partition"      "${TARGET_DISK}"

udevadm settle

# ==============================================================================
# 2. Format Filesystems
# ==============================================================================
echo "==> Formatting partitions..."
mkfs.vfat   -F 32   -n EFI      "${PART_EFI}"
mkfs.ext4   -F      -L boot     "${PART_BOOT}"
mkfs.xfs    -f      -L root     "${PART_ROOT}"
mkfs.xfs    -f      -L sysroot  "${PART_SYSROOT}"

# ==============================================================================
# 3. Execute bootc install to-filesystem
# ==============================================================================
echo "==> Installing bootc container..."

mkdir -p "${MOUNT_DIR}"
mount "${PART_ROOT}" "${MOUNT_DIR}"
mount "${PART_SYSROOT}" "/var/tmp"

bootc install to-filesystem \
    --bootloader=grub \
    --stateroot=default \
    --source-imgref containers-storage:tharsis:latest \
    --target-imgref containers-storage:tharsis:latest \
    --disable-selinux \
    --skip-fetch-check \
    ${MOUNT_DIR}

umount /var/tmp
umount $MOUNT_DIR

# ==============================================================================
# 4. Configure Bootloader
# ==============================================================================

mount $PART_SYSROOT $MOUNT_DIR
mkdir -p $MOUNT_DIR/boot
mount $PART_BOOT $MOUNT_DIR/boot
mkdir -p $MOUNT_DIR/boot/efi/EFI
mount $PART_EFI $MOUNT_DIR/boot/efi/EFI

mkdir -p $MOUNT_DIR/dev $MOUNT_DIR/run $MOUNT_DIR/var $MOUNT_DIR/proc
mount --bind /dev $MOUNT_DIR/dev
mount --bind /proc $MOUNT_DIR/proc

# --update-firmware
bootupctl backend install \
    --auto \
    --write-uuid \
    --device $TARGET_DISK \
    $MOUNT_DIR

# do grub config

# ==============================================================================
# 5. Generate Target /etc/fstab
# ==============================================================================
# bootc install to-filesystem relies on reading /etc/fstab from the target directory
# to populate filesystem UUIDs and kernel boot parameters (e.g. root=UUID=...).
echo "==> Generating target /etc/fstab..."
mkdir -p "${MOUNT_DIR}/etc"

EFI_UUID=$(blkid -s UUID -o value "${PART_EFI}")
BOOT_UUID=$(blkid -s UUID -o value "${PART_BOOT}")
ROOT_UUID=$(blkid -s UUID -o value "${PART_ROOT}")
SYSROOT_UUID=$(blkid -s UUID -o value "${PART_SYSROOT}")

cat <<EOF > "${MOUNT_DIR}/etc/fstab"
UUID=${ROOT_UUID} / xfs defaults 0 0
UUID=${SYSROOT_UUID} /sysroot xfs defaults 0 0
UUID=${BOOT_UUID} /boot ext4 defaults 0 0
UUID=${EFI_UUID} /boot/efi vfat defaults,fmask=0077,dmask=0077 0 2
EOF

echo "Generated fstab:"
cat "${MOUNT_DIR}/etc/fstab"



echo "==> Installation successful! Unmounting target..."