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

rootfs_include_container() {
    local include_image="${1:-}"
    if [ -z "$include_image" ]; then 
        return 0
    fi
    ci_group_start "rootfs-include-container"
    skopeo copy \
        --src-daemon-host unix:///var/run/podman.sock \
        docker-daemon:"${include_image}" \
        containers-storage:[overlay@$ROOTFS/var/lib/containers/storage+$ROOTFS/var/run/containers/storage,mount_program=/usr/bin/fuse-overlayfs,mount_option=nodev]$include_image
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
    rootfs_include_container "$include_image"
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
