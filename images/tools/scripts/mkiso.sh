#!/bin/bash
set -euo pipefail
set -E

NORMAL='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

export ARCH="$(uname -m)"
export CI="${CI:-}"
export CRUN="podman"

export WORKDIR="$(pwd)/tmp"
export ISOROOT="${WORKDIR}/iso-root"
export ROOTFS="${WORKDIR}/rootfs"
export SRC_ROOT="$(pwd)/src"

export HOOK_configure_livesys="${HOOK_configure_livesys:-$SRC_ROOT/hooks/configure_livesys.sh}"
export CLEAN_WORKDIR="${CLEAN_WORKDIR:-true}"
export SIGNING_KEY_LOCATION="${SIGNING_KEY_LOCATION:-/etc/tharsis.pub}"
export KEY_ENROLLMENT_PASSWORD="${KEY_ENROLLMENT_PASSWORD:-tharsis}"
export HOSTNAME_LIVESYS="tharsis"

export DEFAULT_IMAGE="tharsis:latest"
export DEFAULT_ISO_OUTPUT_FILE="$(pwd)/tharsis.iso"
export DEFAULT_ISO_DISK_LABEL="tharsis_boot"
export DEFAULT_COMPRESSION="squashfs"
export DEFAULT_SELINUX_CONTEXTS="${ROOTFS}/etc/selinux/targeted/contexts/files/file_contexts"
export DEFAULT_EXTRA_KARGS=""
export DEFAULT_INCLUDE_IMAGE="$DEFAULT_IMAGE"

ci_group_start() {
    if [ -n "$CI" ]; then
        echo "::group::${1} step"
    fi
}

ci_group_end() {
    if [ -n "$CI" ]; then
        echo "::endgroup::"
    fi
}

clean() {
    local exit_code=$?
    trap - ERR INT TERM EXIT
    grep "$WORKDIR" /proc/mounts | cut -d' ' -f2 | sort -r | xargs -r umount -l 2>/dev/null || true
    if [ "$CLEAN_WORKDIR" != "true" ]; then
        echo -e "${BLUE}Not cleaning ${WORKDIR}. Returning with exit code $exit_code.${NORMAL}" >&2
        return "$exit_code"
    fi
    if [ "$exit_code" -ne 0 ]; then
        echo -e "${RED}Build failed or interrupted (exit code $exit_code)! Cleaning up...${NORMAL}" >&2
    else
        echo -e "${GREEN}Cleaning ${WORKDIR}...${NORMAL}" >&2
    fi
    until rm -rf "$WORKDIR"; do
        sleep 2s
    done
    return "$exit_code"
}

podman_chroot() {
    local cmd="${1}"
    local container_host="$CONTAINER_HOST"
    unset CONTAINER_HOST
    local env_file="$(mktemp)"
    (
        for var in $(compgen -v); do
            if [[ ! "$var" =~ ^(BASH.*|EUID|PPID|UID|GROUPS|FUNCNAME|COMP_.*|DIRSTACK|HIST.*|LINENO|SECONDS|SHELLOPTS|OPTERR|OPTIND|IFS)$ ]]; then
                export "$var" 2>/dev/null || true
            fi
        done
        env
    ) > "$env_file"
    $CRUN run --rm -it \
        --net host \
        --privileged \
        --tmpfs /tmp:rw \
        --tmpfs /run:rw \
        --volume $(pwd):/app \
        --env-file "$env_file" \
        --rootfs "$ROOTFS" \
        sh -c "$cmd"
    rm -f "$env_file"
    export CONTAINER_HOST="$container_host"
}

chroot_chroot() {
    local cmd="${1}"
    local container_host="$CONTAINER_HOST"
    unset CONTAINER_HOST
    mount -t proc /proc "$ROOTFS/proc"
    mount --bind /sys "$ROOTFS/sys"
    mount --bind /dev "$ROOTFS/dev"
    mount --bind /dev/pts "$ROOTFS/dev/pts"
    mount -t tmpfs none "$ROOTFS/tmp"
    mount -t tmpfs none "$ROOTFS/run"
    mount --bind /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
    mkdir -p "$ROOTFS/app"
    mount --bind /app "$ROOTFS/app"
    chroot "$ROOTFS" sh -c "$cmd"
    umount -l "$ROOTFS/app"
    rmdir "$ROOTFS/app"
    umount -l "$ROOTFS/etc/resolv.conf"
    umount -l "$ROOTFS/run"
    umount -l "$ROOTFS/tmp"
    umount -l "$ROOTFS/dev/pts"
    umount -l "$ROOTFS/dev"
    umount -l "$ROOTFS/sys"
    umount -l "$ROOTFS/proc"
    export CONTAINER_HOST="$container_host"
}

init_work() {
    echo -e "${GREEN}Ensuring Work Directories...${NORMAL}" >&2
    mkdir -p "$WORKDIR"
    mkdir -p "$ISOROOT"
    mkdir -p "$ROOTFS"
}

rootfs_bootstrap() {
    if [ -f $ROOTFS/usr/bin/sh ]; then
        return 0
    fi
    ci_group_start "rootfs-bootstrap"
    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --include=ca-certificates,bash-completion \
        trixie \
        $ROOTFS \
        http://ftp.de.debian.org/debian/
    rm -Rf $ROOTFS/debootstrap
    ci_group_end
}

rootfs_extract_image() {
    local image="${1:-}"
    if [ -z "$image" ]; then 
        echo -e "${RED}Error: No base image specified for rootfs.${NORMAL}" >&2
        return 1
    fi
    ctr_id="$($CRUN create --rm "$image" /usr/bin/bash)"
    local imagefs="$ROOTFS/tmp/imagefs"
    mkdir -p $imagefs
    trap '$CRUN rm -f "$ctr_id"; rm -Rf "$imagefs" 2>/dev/null || true' ERR INT TERM EXIT
    $CRUN export "$ctr_id" | \
        tar --checkpoint=1000 \
            --checkpoint-action='ttyout=Processing %s: %T (Checkpoint #%u)\r' \
            --xattrs-include='*' \
            --overwrite \
            -p -xf - \
            -C $imagefs
    $CRUN rm -f "$ctr_id" 2>/dev/null || true
    trap - ERR INT TERM EXIT
    rsync -a $imagefs/. $ROOTFS/ \
        --exclude sysroot --exclude boot --exclude lib/ostree --exclude var \
        --exclude ostree --exclude root --exclude srv \
        --exclude opt --exclude mnt --exclude home --exclude usr/local && \
    rm -Rf "$imagefs"
}

rootfs_include_container() {
    local include_image="${1:-}"
    if [ -z "$include_image" ]; then 
        return 0
    fi
    ci_group_start "rootfs-include-container"
    skopeo copy \
        --src-daemon-host unix:///var/run/podman.sock \
        docker-daemon:"${include_image}" \
        containers-storage:[vfs@$ROOTFS/var/lib/containers/storage+$ROOTFS/var/run/containers/storage]$include_image
    ci_group_end
}

rootfs_install_livesys() {
    ci_group_start "rootfs-install-livesys"
    local CMD='set -xeuo pipefail
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y linux-image-amd64 live-boot calamares calamares-settings-debian podman'
    chroot_chroot "$CMD"
    ci_group_end
}

rootfs_configure_livesys() {
    local hook="${1:-}"
    if [ -z "$hook" ]; then
        return 0
    fi
    ci_group_start "rootfs-configure-livesys"
    chroot_chroot "$(cat "$hook")"
    ci_group_end
}

rootfs_clean() {
    ci_group_start "rootfs-clean"
    local CMD='set -xeuo pipefail
    apt clean'
    chroot_chroot "$CMD"
    ci_group_end
}

rootfs_squash() {
    local fs_type="${1:-}"
    local selinux_contexts="${2:-}"
    # if [ ! -f "$selinux_contexts" ]; then
    #     echo -e "${RED}ERROR[squash]: SELinux context not found:${NORMAL} $selinux_contexts" >&2
    #     exit 1
    # fi
    ci_group_start "squash"
    if [ "$fs_type" == "squashfs" ]; then
        #--selinux "${selinux_contexts}" \
        gensquashfs \
            --pack-dir "${ROOTFS}" \
            --force \
            --defaults uid=0,gid=0 \
            "${WORKDIR}/filesystem.squashfs"
    elif [ "$fs_type" == "erofs" ]; then
        mkfs.erofs -d0 --quiet --all-root \
            -zlz4hc,6 \
            -Eall-fragments,fragdedupe=inode \
            -C1048576 \
            --file-contexts="${selinux_contexts}" \
            "${WORKDIR}/filesystem.squashfs" \
            "${ROOTFS}"
    else
        echo -e "${RED}ERROR[squash]: Invalid Compression${NORMAL}" >&2
        ci_group_end
        exit 1
    fi
    ci_group_end
}

iso_prepare() {
    ci_group_start "iso_prepare"
    mkdir -p "${ISOROOT}/boot" "${ISOROOT}/live" "${ISOROOT}/isolinux"
    cp ${ROOTFS}/boot/vmlinuz-* "${ISOROOT}/live/vmlinuz"
    cp ${ROOTFS}/boot/initrd.img-* "${ISOROOT}/live/initrd.img"
    mv "${WORKDIR}/filesystem.squashfs" "${ISOROOT}/live/"
    ci_group_end
}

iso_bootloader() {
    local extra_kargs="${1:-}"
    local iso_disk_label="${2:-}"
    ci_group_start "iso_bootloader"
    local kargs=()
    if [ -n "$extra_kargs" ]; then
        IFS=',' read -r -a kargs <<< "$extra_kargs"
    fi
    local ARCH_EFI=""
    local ARCH_SHORT=""
    case "$ARCH" in
        x86_64)
            ARCH_EFI="x86_64-efi"
            ARCH_SHORT="x64"
            ;;
        aarch64)
            ARCH_EFI="arm64-efi"
            ARCH_SHORT="aa64"
            ;;
        *)
            echo -e "${RED}ERROR[iso]: Unsupported architecture: $ARCH${NORMAL}" >&2
            exit 1
            ;;
    esac
    mkdir -p "${ISOROOT}/boot/grub/${ARCH_EFI}" "${ISOROOT}/isolinux" "${ISOROOT}/EFI/BOOT"
    cat "${SRC_ROOT}/boot/grub.cfg.tmpl" | \
        sed \
        -e "s|@DISK_LABEL@|${iso_disk_label}|g" \
        -e "s|@EXTRA_KARGS@|${kargs[*]}|g" \
        > "${ISOROOT}/boot/grub/grub.cfg"
    cat "${SRC_ROOT}/boot/isolinux.cfg.tmpl" \
        > "${ISOROOT}/isolinux/isolinux.cfg"
    cp /usr/lib/ISOLINUX/isolinux.bin "${ISOROOT}/isolinux/"
    cp /usr/lib/syslinux/modules/bios/* "${ISOROOT}/isolinux/"
    cp -r /usr/lib/grub/x86_64-efi/* "${ISOROOT}/boot/grub/${ARCH_EFI}"
    cat > "${WORKDIR}/grub-embed.cfg" <<'EOF'
if ! [ -d "$cmdpath" ]; then
    # On some firmware, GRUB has a wrong cmdpath when booted from an optical disc.
    # https://gitlab.archlinux.org/archlinux/archiso/-/issues/183
    if regexp --set=1:isodevice '^(\([^)]+\))\/?[Ee][Ff][Ii]\/[Bb][Oo][Oo][Tt]\/?$' "$cmdpath"; then
        cmdpath="${isodevice}/EFI/BOOT"
    fi
fi
configfile "${cmdpath}/grub.cfg"
EOF
    grub-mkstandalone -O i386-efi \
        --modules="part_gpt part_msdos fat iso9660" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${ISOROOT}/EFI/BOOT/BOOTIA32.EFI" \
        "boot/grub/grub.cfg=${WORKDIR}/grub-embed.cfg"
    grub-mkstandalone -O x86_64-efi \
        --modules="part_gpt part_msdos fat iso9660" \
        --locales="" \
        --themes="" \
        --fonts="" \
        --output="${ISOROOT}/EFI/BOOT/BOOTx64.EFI" \
        "boot/grub/grub.cfg=${WORKDIR}/grub-embed.cfg"
    cp "${ISOROOT}/boot/grub/grub.cfg" ${ISOROOT}/EFI/BOOT/
    local efiboot="${ISOROOT}/efiboot.img"
    dd if=/dev/zero of=$efiboot bs=1M count=25 && \
    mkfs.vfat $efiboot && \
    mmd -i $efiboot ::/EFI ::/EFI/BOOT && \
    mcopy -vi $efiboot \
        "${ISOROOT}/EFI/BOOT/BOOTIA32.EFI" \
        "${ISOROOT}/EFI/BOOT/BOOTx64.EFI" \
        "${ISOROOT}/boot/grub/grub.cfg" \
        ::/EFI/BOOT/
    ci_group_end
}

iso_create() {
    local iso_output_file="${1:-}"
    local iso_disk_label="${2:-}"

    if [ -z "$iso_output_file" ]; then
        echo -e "${RED}ERROR[iso]: No output file for iso specified${NORMAL}" >&2
        exit 1
    fi
    if [ -z "$iso_disk_label" ]; then
        echo -e "${RED}ERROR[iso]: No disk label specified${NORMAL}" >&2
        exit 1
    fi
    ci_group_start "iso"
    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -o "${iso_output_file}" \
        -full-iso9660-filenames \
        -volid "${iso_disk_label}" \
        --mbr-force-bootable -partition_offset 16 \
        -joliet -joliet-long -rational-rock \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-boot \
            isolinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog isolinux/isolinux.cat \
        -eltorito-alt-boot \
            -e --interval:appended_partition_2:all:: \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "${ISOROOT}/efiboot.img" \
        "$ISOROOT"
    ci_group_end
}

show_config() {
    local image="${1:-$DEFAULT_IMAGE}"
    local iso_output_file="${2:-$DEFAULT_ISO_OUTPUT_FILE}"
    local iso_disk_label="${3:-$DEFAULT_ISO_DISK_LABEL}"
    local include_image="${4:-$DEFAULT_INCLUDE_IMAGE}"
    local compression="${5:-$DEFAULT_COMPRESSION}"
    local selinux_contexts="${6:-$DEFAULT_SELINUX_CONTEXTS}"
    local extra_kargs="${7:-$DEFAULT_EXTRA_KARGS}"
    echo "Using the following configuration:"
    echo -e "${YELLOW}################################################################################${NORMAL}"
    echo "image                     := $image"
    echo "iso_output_file           := $iso_output_file"
    echo "iso_disk_label            := $iso_disk_label"
    echo "include_image             := $include_image"
    echo "compression               := $compression"
    echo "selinux_contexts          := $selinux_contexts"
    echo "extra_kargs               := $extra_kargs"
    echo "CLEAN_WORKDIR             := $CLEAN_WORKDIR"
    echo "ARCH                      := $ARCH"
    echo "HOOK_configure_livesys    := $HOOK_configure_livesys"
    echo "HOSTNAME_LIVESYS          := $HOSTNAME_LIVESYS"
    echo "CI                        := $CI"
    echo -e "${YELLOW}################################################################################${NORMAL}"
    sleep 1
}

build() {
    local image="${1:-$DEFAULT_IMAGE}"
    local iso_output_file="${2:-$DEFAULT_ISO_OUTPUT_FILE}"
    local iso_disk_label="${3:-$DEFAULT_ISO_DISK_LABEL}"
    local include_image="${4:-$DEFAULT_INCLUDE_IMAGE}"
    local compression="${5:-$DEFAULT_COMPRESSION}"
    local selinux_contexts="${6:-$DEFAULT_SELINUX_CONTEXTS}"
    local extra_kargs="${7:-$DEFAULT_EXTRA_KARGS}"
    show_config "$image" "$iso_output_file" "$iso_disk_label" "$include_image" "$compression" "$selinux_contexts" "$extra_kargs"
    clean
    trap clean ERR INT TERM EXIT
    init_work
    rootfs_bootstrap
    rootfs_extract_image "$image"
    rootfs_include_container "$include_image"
    rootfs_install_livesys
    rootfs_configure_livesys "$HOOK_configure_livesys"
    rootfs_clean
    rootfs_squash "$compression" "$selinux_contexts"
    iso_prepare
    iso_bootloader "$extra_kargs" "$iso_disk_label"
    iso_create "$iso_output_file" "$iso_disk_label"
}

usage() {
    echo "Usage: $0 [command] [args...]"
    echo "Commands:"
    echo "  build"
    echo "    [image=$DEFAULT_IMAGE]"
    echo "    [iso_output_file=$DEFAULT_ISO_OUTPUT_FILE]"
    echo "    [iso_disk_label=$DEFAULT_ISO_DISK_LABEL]"
    echo "    [include_image=$DEFAULT_INCLUDE_IMAGE]"
    echo "    [compression=$DEFAULT_COMPRESSION]"
    echo "    [selinux_contexts=$DEFAULT_SELINUX_CONTEXTS]"
    echo "    [extra_kargs=$DEFAULT_EXTRA_KARGS]"
    echo "  clean"
    echo "  show-config"
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    build)
        build "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
        ;;
    clean)
        clean
        ;;
    show-config)
        show_config
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NORMAL}"
        usage
        ;;
esac

clean
