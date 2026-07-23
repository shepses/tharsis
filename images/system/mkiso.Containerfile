FROM fedora-base:latest

RUN dnf install -y make automake rsync openssl-devel fuse-overlayfs podman skopeo qemu-kvm

RUN	mkdir -p \
	/app \
	/etc/containers \
	/usr/local/bin \
	/var/lib/flatpak
# ADD <<"EOF" /etc/containers/containers.conf
# [engine]
# cgroups = "disabled"
# events_logger = "none"
# helper_binaries_dir = ["/usr/libexec/podman"]
# EOF

# ADD <<"EOF" /etc/containers/registries.d/ghcr.yaml
# docker:
#   ghcr.io:
#     use-sigstore-attachments: true
# EOF

RUN wget https://github.com/sigstore/cosign/releases/download/v3.1.2/cosign-3.1.2-1.x86_64.rpm && \
	rpm -ivh cosign-3.1.2-1.x86_64.rpm

RUN dnf install -y \
	grub2-efi-x64 grub2-efi-x64-modules grub2-pc-modules grub2-tools-extra shim \
	xorriso squashfs-tools-ng mkfs.erofs dosfstools

WORKDIR /app

COPY --chmod=755 scripts/mkiso.sh /usr/local/bin/mkiso

CMD ["/usr/local/bin/mkiso"]

# VERSION: 1.0.0