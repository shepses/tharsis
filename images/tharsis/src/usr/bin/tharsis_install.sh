#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
TARGET_DISK="${1:-/dev/vda}"
IMAGE_REF="${2:-quay.io/fedora/fedora-bootc:40}"
MOUNT_DIR="/mnt/target"

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

# ==============================================================================
# 1. Disk Partitioning (GPT)
# ==============================================================================
echo "==> Wiping and partitioning disk ${TARGET_DISK}..."
wipefs -a -f "${TARGET_DISK}"
sgdisk --zap-all "${TARGET_DISK}"

# Create GPT Partitions:
# 1: EFI System Partition (512M) - Type C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# 2: /boot Partition (1024M)     - Type BC13C2FF-59E6-4262-A352-B275FD6F7172 (XBOOTLDR/Boot)
# 3: Root Partition (Rest)       - Type 4F688204-4011-4F12-9A6C-2D54177E25C7 (Linux Root x86-64)
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "${TARGET_DISK}"
sgdisk -n 2:0:+1024M -t 2:ea00 -c 2:"Boot Partition" "${TARGET_DISK}"
sgdisk -n 3:0:0     -t 3:8304 -c 3:"Root Partition" "${TARGET_DISK}"

udevadm settle

# ==============================================================================
# 2. Format Filesystems
# ==============================================================================
echo "==> Formatting partitions..."
mkfs.vfat -F 32 -n EFI "${PART_EFI}"
mkfs.ext4 -F -L boot "${PART_BOOT}"
mkfs.xfs -f -L root "${PART_ROOT}"

# ==============================================================================
# 3. Mount Hierarchy
# ==============================================================================
echo "==> Mounting filesystems under ${MOUNT_DIR}..."
mkdir -p "${MOUNT_DIR}"
mount "${PART_ROOT}" "${MOUNT_DIR}"

mkdir -p "${MOUNT_DIR}/boot"
mount "${PART_BOOT}" "${MOUNT_DIR}/boot"

mkdir -p "${MOUNT_DIR}/boot/efi"
mount "${PART_EFI}" "${MOUNT_DIR}/boot/efi"

# Cleanup trap to ensure unmounting on error or completion
cleanup() {
    echo "==> Cleaning up mounts..."
    umount -R "${MOUNT_DIR}" || true
}
trap cleanup EXIT

# ==============================================================================
# 4. Generate Target /etc/fstab
# ==============================================================================
# bootc install to-filesystem relies on reading /etc/fstab from the target directory
# to populate filesystem UUIDs and kernel boot parameters (e.g. root=UUID=...).
echo "==> Generating target /etc/fstab..."
mkdir -p "${MOUNT_DIR}/etc"

EFI_UUID=$(blkid -s UUID -o value "${PART_EFI}")
BOOT_UUID=$(blkid -s UUID -o value "${PART_BOOT}")
ROOT_UUID=$(blkid -s UUID -o value "${PART_ROOT}")

cat <<EOF > "${MOUNT_DIR}/etc/fstab"
UUID=${ROOT_UUID} / xfs defaults 0 0
UUID=${BOOT_UUID} /boot ext4 defaults 0 0
UUID=${EFI_UUID} /boot/efi vfat defaults,fmask=0077,dmask=0077 0 2
EOF

echo "Generated fstab:"
cat "${MOUNT_DIR}/etc/fstab"

# ==============================================================================
# 5. Execute bootc install to-filesystem
# ==============================================================================
echo "==> Installing bootc container..."

bootc install to-filesystem \
    --bootloader=grub \
    --stateroot=default \
    --source-imgref containers-storage:tharsis:latest \
    --target-imgref containers-storage:tharsis:latest \
    --disable-selinux \
    --skip-fetch-check \
    "${MOUNT_DIR}"

echo "==> Installation successful! Unmounting target..."
