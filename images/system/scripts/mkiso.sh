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

export HOOK_post_rootfs="${HOOK_post_rootfs:-$SRC_ROOT/hooks/prep_rootfs.sh}"
export HOOK_pre_initramfs="${HOOK_pre_initramfs:-$SRC_ROOT/hooks/prep_initramfs.sh}"
export DISABLE_CLEAN="${DISABLE_CLEAN:-true}"
export SIGNING_KEY_LOCATION="${SIGNING_KEY_LOCATION:-/etc/sb_pubkey.der}"
export KEY_ENROLLMENT_PASSWORD="${KEY_ENROLLMENT_PASSWORD:-secureblue}"
export OCI_ROOTFS_LOCATION="$(pwd)/oci_rootfs.tar"

export DEFAULT_IMAGE="ghcr.io/secureblue/kinoite-nvidia-open-hardened:latest"
export DEFAULT_ISO_OUTPUT_FILE="$(pwd)/output.iso"
export DEFAULT_ISO_DISK_LABEL="tharsis_boot"
export DEFAULT_INCLUDE_LIVESYS_SCRIPTS="true"
export DEFAULT_FLATPAKS_FILE="${SRC_ROOT}/flatpaks.txt"
export DEFAULT_COMPRESSION="squashfs"
export DEFAULT_SELINUX_CONTEXTS="${ROOTFS}/etc/selinux/targeted/contexts/files/file_contexts"
export DEFAULT_EXTRA_KARGS=""
export DEFAULT_INCLUDE_IMAGE="$DEFAULT_IMAGE"
export DEFAULT_INCLUDE_POLKIT="true"

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

chroot_function() {
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

clean() {
    local clean="${1:-}"
    local exit_code=$?
    trap - ERR INT TERM EXIT
    grep "$WORKDIR" /proc/mounts | cut -d' ' -f2 | sort -r | xargs -r umount -l 2>/dev/null || true
    if [ "$DISABLE_CLEAN" == "true" ]; then
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

init_work() {
    echo -e "${GREEN}Ensuring Work Directories...${NORMAL}" >&2
    mkdir -p "$WORKDIR"
    mkdir -p "$ISOROOT"
    mkdir -p "$ROOTFS"
}

rootfs_extract() {
    local image="${1:-}"
    if [ -z "$image" ]; then 
        echo -e "${RED}No rootfs container image specified${NORMAL}" >&2
        exit 1
    fi
    ci_group_start "rootfs"
    if [ -d "$ROOTFS/usr" ]; then
        echo -e "${BLUE}Using existing rootfs $ROOTFS ...${NORMAL}" >&2
        ci_group_end "rootfs"
        return 0
    fi
    $CRUN pull "$image"
    ctr_id="$($CRUN create --rm "$image" /usr/bin/bash)"
    trap '$CRUN rm -f "$ctr_id" 2>/dev/null || true' EXIT
    $CRUN export "$ctr_id" | \
        tar --xattrs-include='*' \
            --checkpoint=1000 \
            --checkpoint-action='ttyout=Processing %s: %T (Checkpoint #%u)\r' \
            -p -xf - -C "$ROOTFS"
    $CRUN rm -f "$ctr_id" 2>/dev/null || true
    trap - EXIT
    mkdir -p "$ROOTFS/tmp" "$ROOTFS/app" "$ROOTFS/run" \
             "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/dev/pts"
    ln -sr "${ROOTFS}/run" "${ROOTFS}/var/run"
    rm -rf "${ROOTFS}/var/tmp"
    ln -sr "${ROOTFS}/tmp" "${ROOTFS}/var/tmp"
    ci_group_end
}

hook_pre_initramfs() {
    local hook="${1:-}"
    if [ -z "$hook" ]; then
        return 0
    fi
    ci_group_start "hook-pre-initramfs"
    chroot_function "$(cat "$hook")"
    ci_group_end
}

initramfs() {
    ci_group_start "initramfs"
    local CMD
    CMD='set -xeuo pipefail
    dnf install -y dracut-live util-linux dracut-network
    INSTALLED_KERNEL=$(rpm -q kernel-core --queryformat "%{evr}.%{arch}" | tail -n 1)
    mkdir -p $(realpath /root)
    export DRACUT_NO_XATTR=1
    dracut --zstd --reproducible --no-hostonly --kver "$INSTALLED_KERNEL" --add "dmsquash-live dmsquash-live-autooverlay" --add-drivers "sunrpc" --force '"${WORKDIR}"'/initramfs.img 2>&1 | grep -v -e "Operation not supported" -e "/dev/kmsg"'
    chroot_function "$CMD"
    ci_group_end
}

rootfs_include_polkit() {
    local include_polkit="${1:-}"
    if [ "$include_polkit" != "true" ]; then
        return 0
    fi
    ci_group_start "rootfs-include-polkit"
    install -D -m 0644 "${SRC_ROOT}"/polkit-1/rules.d/*.rules -t "${ROOTFS}/etc/polkit-1/rules.d"
    ci_group_end
}

rootfs_include_livesys_scripts() {
    local include_livesys_scripts="${1:-}"
    if [ "$include_livesys_scripts" != "true" ]; then
        return 0
    fi
    ci_group_start "rootfs-install-livesys-scripts"
    local CMD
    CMD='set -xeuo pipefail
    dnf install -y livesys-scripts
    desktop_env=""
    _session_file="$(find /usr/share/wayland-sessions/ /usr/share/xsessions \
        -maxdepth 1 -type f -not -name '*gamescope*.desktop' -and -name '*.desktop' -printf '%P' -quit)"
    case $_session_file in
        budgie*) desktop_env=budgie ;;
        cosmic*) desktop_env=cosmic ;;
        gnome*)  desktop_env=gnome  ;;
        plasma*) desktop_env=kde    ;;
        sway*)   desktop_env=sway   ;;
        xfce*)   desktop_env=xfce   ;;
        *) echo -e "\033[0;31mERROR[rootfs-install-livesys-scripts]\033[0m: No Livesys Environment Found"; exit 1 ;;
    esac && unset -v _session_file
    sed -i "s/^livesys_session=.*/livesys_session=${desktop_env}/" /etc/sysconfig/livesys
    systemctl enable livesys.service livesys-late.service
    echo "C /var/lib/livesys/livesys-session-extra 0755 root root - /usr/share/factory/var/lib/livesys/livesys-session-extra" > /usr/lib/tmpfiles.d/livesys-session-extra.conf'
    chroot_function "$CMD"
    install -D -m 0644 "${SRC_ROOT}/livesys-session-extra" "${ROOTFS}/usr/share/factory/var/lib/livesys/livesys-session-extra"
    ci_group_end
}

rootfs_include_container() {
    local include_image="${1:-}"
    if [ -z "$include_image" ]; then 
        return 0
    fi
    ci_group_start "rootfs-include-container"
    mkdir -p $ROOTFS/var/lib/containers/storage
    mkdir -p $ROOTFS/usr/etc/pki/containers
    cp $ROOTFS/usr/share/pki/containers/secureblue-2025.pub $ROOTFS/usr/etc/pki/containers/secureblue-2025.pub
    cp $ROOTFS/usr/share/pki/containers/secureblue.pub $ROOTFS/usr/etc/pki/containers/secureblue.pub
    skopeo copy \
        --src-daemon-host unix:///var/run/podman.sock \
        docker-daemon:"${include_image}" \
        containers-storage:[overlay@/"${ROOTFS}/var/lib/containers/storage]${include_image}"
    # TODO: copying image over unix socket drops signature, thus disable signature verfication
    # in src/hooks/prep_rootfs.sh. we will eventually use our own key and re-sign above with 
    # `skopeo copy --sign-by`
    ci_group_end
}

rootfs_include_flatpaks() {
    local flatpaks_file="${1:-}"
    if [ -z "$flatpaks_file" ]; then
        return 0
    fi
    if [ ! -f "$flatpaks_file" ]; then
        echo -e "${RED}Flatpak file inaccessible: $flatpaks_file${NORMAL}" >&2
        exit 1
    fi
    ci_group_start "rootfs-include-flatpaks"
    local CMD
    CMD='set -xeuo pipefail
    mkdir -p /var/lib/flatpak
    dnf install -y flatpak
    flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    grep -v "#.*" '"$flatpaks_file"' | xargs "-i{}" -d "\n" sh -c \
        "flatpak remote-info --arch='"$ARCH"' --system flathub {} &>/dev/null && \
        flatpak install --noninteractive -y {}"'
    chroot_function "$CMD"
    ci_group_end
}

hook_post_rootfs() {
    local hook="${1:-}"
    if [ -z "$hook" ]; then
        return 0
    fi
    ci_group_start "hook-post-rootfs"
    chroot_function "$(cat "$hook")"
    ci_group_end
}

rootfs_clean_sysroot() {
    ci_group_start "rootfs-clean-sysroot"
    local CMD
    CMD='set -xeuo pipefail
    if [ -d /app ]; then
        rm -rf /sysroot /ostree
        dnf autoremove -y
        dnf clean all -y
    fi'
    chroot_function "$CMD"
    ci_group_end
}

squash() {
    local fs_type="${1:-}"
    local selinux_contexts="${2:-}"
    if [ ! -f "$selinux_contexts" ]; then
        echo -e "${RED}ERROR[squash]: SELinux context not found:${NORMAL} $selinux_contexts" >&2
        exit 1
    fi
    ci_group_start "squash"
    if [ "$fs_type" == "squashfs" ]; then
        gensquashfs \
            --pack-dir "${ROOTFS}" \
            --force \
            --defaults uid=0,gid=0 \
            --selinux "${selinux_contexts}" \
            "${WORKDIR}/squashfs.img"
    elif [ "$fs_type" == "erofs" ]; then
        mkfs.erofs -d0 --quiet --all-root \
            -zlz4hc,6 \
            -Eall-fragments,fragdedupe=inode \
            -C1048576 \
            --file-contexts="${selinux_contexts}" \
            "${WORKDIR}/squashfs.img" \
            "${ROOTFS}"
    else
        echo -e "${RED}ERROR[squash]: Invalid Compression${NORMAL}" >&2
        ci_group_end
        exit 1
    fi
    ci_group_end
}

process_grub_template() {
    local extra_kargs="${1:-}"
    ci_group_start "process-grub-template"
    local kargs=()
    if [ -n "$extra_kargs" ]; then
        IFS=',' read -r -a kargs <<< "$extra_kargs"
    fi
    local OS_RELEASE="${ROOTFS}/usr/lib/os-release"
    local TMPL="${SRC_ROOT}/boot/grub.cfg.tmpl"
    local DEST="${ISOROOT}/boot/grub/grub.cfg"
    local PRETTY_NAME
    PRETTY_NAME="$(source "$OS_RELEASE" 2>/dev/null && echo "${PRETTY_NAME%% (*)}")"
    mkdir -p "$(dirname "$DEST")"
    sed \
        -e "s|@PRETTY_NAME@|${PRETTY_NAME}|g" \
        -e "s|@EXTRA_KARGS@|${kargs[*]}|g" \
        "$TMPL" > "$DEST"
    ci_group_end
}

iso_organize() {
    ci_group_start "iso-organize"
    mkdir -p "${ISOROOT}/boot/grub" "${ISOROOT}/LiveOS"
    cp "${ROOTFS}"/lib/modules/*/vmlinuz "${ISOROOT}/boot"
    cp "${WORKDIR}/initramfs.img" "${ISOROOT}/boot"
    mv "${WORKDIR}/squashfs.img" "${ISOROOT}/LiveOS/squashfs.img"
    ci_group_end
}

iso() {
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
    ARCH_SHORT="$(echo "$ARCH" | sed 's/x86_64/x64/g' | sed 's/aarch64/aa64/g')"
    ARCH_32="$(echo "$ARCH" | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"
    mkdir -p $ISOROOT/EFI/BOOT
    cp -avf ${SRC_ROOT}/boot/efi/. $ISOROOT/EFI/BOOT
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg
    cp -avf /boot/grub*/fonts/unicode.pf2 $ISOROOT/EFI/BOOT/fonts 2>/dev/null || true
    cp -avf $ISOROOT/EFI/BOOT/shim${ARCH_SHORT}.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT^^}.efi" 2>/dev/null || true
    cp -avf $ISOROOT/EFI/BOOT/shim.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_32}.efi" 2>/dev/null || true
    ARCH_GRUB="$(echo "$ARCH" | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(echo "$ARCH" | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(echo "$ARCH" | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"
    grub2-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES
    grub2-mkrescue -o $WORKDIR/efiboot.img
    osirrox -indev $WORKDIR/efiboot.img -extract /boot/grub "$ISOROOT/boot/"
    fallocate $WORKDIR/efiboot.img -l 25M
    mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    mmd -i "$WORKDIR/efiboot.img" ::/EFI ::/EFI/BOOT
    mcopy -i "$WORKDIR/efiboot.img" -s "$ISOROOT/EFI/BOOT/"* ::/EFI/BOOT/
    ARCH_SPECIFIC=()
    if [ "$ARCH" == "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi
    xorrisofs \
        -R \
        -V "${iso_disk_label}" \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        "$WORKDIR/efiboot.img" \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -c boot.cat --boot-catalog-hide \
        -b boot/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e \
        --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -vvvvv \
        -iso-level 3 \
        -o "${iso_output_file}" \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT
    ci_group_end
}

show_config() {
    local image="${1:-$DEFAULT_IMAGE}"
    local iso_output_file="${2:-$DEFAULT_ISO_OUTPUT_FILE}"
    local iso_disk_label="${3:-$DEFAULT_ISO_DISK_LABEL}"
    local include_image="${4:-$DEFAULT_INCLUDE_IMAGE}"
    local flatpaks_file="${5:-$DEFAULT_FLATPAKS_FILE}"
    local compression="${6:-$DEFAULT_COMPRESSION}"
    local selinux_contexts="${7:-$DEFAULT_SELINUX_CONTEXTS}"
    local extra_kargs="${8:-$DEFAULT_EXTRA_KARGS}"
    local include_polkit="${9:-$DEFAULT_INCLUDE_POLKIT}"
    local include_livesys_scripts="${10:-$DEFAULT_INCLUDE_LIVESYS_SCRIPTS}"
    echo "Using the following configuration:"
    echo -e "${YELLOW}################################################################################${NORMAL}"
    echo "image                     := $image"
    echo "iso_output_file           := $iso_output_file"
    echo "iso_disk_label            := $iso_disk_label"
    echo "include_image             := $include_image"
    echo "flatpaks_file             := $flatpaks_file"
    echo "compression               := $compression"
    echo "selinux_contexts          := $selinux_contexts"
    echo "extra_kargs               := $extra_kargs"
    echo "polkit                    := $include_polkit"
    echo "include_livesys_scripts   := $include_livesys_scripts"
    echo "DISABLE_CLEAN             := $DISABLE_CLEAN"
    echo "ARCH                      := $ARCH"
    echo "HOOK_post_rootfs          := $HOOK_post_rootfs"
    echo "HOOK_pre_initramfs        := $HOOK_pre_initramfs"
    echo "CI                        := $CI"
    echo -e "${YELLOW}################################################################################${NORMAL}"
    sleep 1
}

build() {
    local image="${1:-$DEFAULT_IMAGE}"
    local iso_output_file="${2:-$DEFAULT_ISO_OUTPUT_FILE}"
    local iso_disk_label="${3:-$DEFAULT_ISO_DISK_LABEL}"
    local include_image="${4:-$DEFAULT_INCLUDE_IMAGE}"
    local flatpaks_file="${5:-$DEFAULT_FLATPAKS_FILE}"
    local compression="${6:-$DEFAULT_COMPRESSION}"
    local selinux_contexts="${7:-$DEFAULT_SELINUX_CONTEXTS}"
    local extra_kargs="${8:-$DEFAULT_EXTRA_KARGS}"
    local include_polkit="${9:-$DEFAULT_INCLUDE_POLKIT}"
    local include_livesys_scripts="${10:-$DEFAULT_INCLUDE_LIVESYS_SCRIPTS}"
    show_config "$image" "$iso_output_file" "$iso_disk_label" "$include_image" "$flatpaks_file" "$compression" "$selinux_contexts" "$extra_kargs" "$include_polkit" "$include_livesys_scripts"
    clean
    trap clean ERR INT TERM EXIT
    init_work
    rootfs_extract "$image"
    rootfs_include_polkit "$include_polkit"
    rootfs_include_livesys_scripts "$include_livesys_scripts"
    rootfs_include_flatpaks "$flatpaks_file"
    rootfs_include_container "$include_image"
    hook_pre_initramfs "$HOOK_pre_initramfs"
    initramfs
    hook_post_rootfs "$HOOK_post_rootfs" 
    rootfs_clean_sysroot
    squash "$compression" "$selinux_contexts"
    process_grub_template "$extra_kargs"
    iso_organize
    iso "$iso_output_file" "$iso_disk_label"
}

usage() {
    echo "Usage: $0 [command] [args...]"
    echo "Commands:"
    echo "  build"
    echo "    [image=$DEFAULT_IMAGE]"
    echo "    [iso_output_file=$DEFAULT_ISO_OUTPUT_FILE]"
    echo "    [iso_disk_label=$DEFAULT_ISO_DISK_LABEL]"
    echo "    [include_image=$DEFAULT_INCLUDE_IMAGE]"
    echo "    [flatpaks_file=$DEFAULT_FLATPAKS_FILE]"
    echo "    [compression=$DEFAULT_COMPRESSION]"
    echo "    [selinux_contexts=$DEFAULT_SELINUX_CONTEXTS]"
    echo "    [extra_kargs=$DEFAULT_EXTRA_KARGS]"
    echo "    [include_polkit=$DEFAULT_INCLUDE_POLKIT]"
    echo "    [include_livesys_scripts=$DEFAULT_INCLUDE_LIVESYS_SCRIPTS]"
    echo "  clean"
    echo "  init-work"
    echo "  rootfs"
    echo "    [image=$DEFAULT_IMAGE]"
    echo "  initramfs"
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
        build "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}"
        ;;
    clean)
        clean
        ;;
    init-work)
        init_work
        ;;
    rootfs)
        rootfs_extract "${1:-}"
        ;;
    initramfs)
        initramfs
        ;;
    show-config)
        show_config
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NORMAL}"
        usage
        ;;
esac

#clean
