# Tharsis
This repo contains the code for an upcoming operating system based on bootable containers.

# usage:
`make images`: 
```bash
.PHONY: images
images:
	@podman run -it \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock:Z" \
		-v "./images":/app \
		-w /app \
		podman:latest \
		sh /app/build.sh
```

`make iso`: Remember to start podman socket first `systemctl start --user podman.socket`
```bash
.PHONY: iso
DISABLE_CLEAN="true"
iso:
	@podman run -it \
		--privileged \
		--env DISABLE_CLEAN=$(DISABLE_CLEAN) \
		--env HOOK_post_rootfs=/app/src/hooks/prep_rootfs.sh \
		--env HOOK_pre_initramfs=/app/src/hooks/prep_initramfs.sh \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock:Z" \
		-v "./iso":/app \
		-w /app \
		mkiso:latest \
		mkiso build
```

`podman run mkiso:latest`: 
```bash
Usage: /usr/local/bin/mkiso [command] [args...]
Commands:
  build
    [image=ghcr.io/secureblue/kinoite-nvidia-open-hardened:latest]
    [iso_output_file=/app/output.iso]
    [iso_disk_label=tharsis_boot]
    [include_image=ghcr.io/secureblue/kinoite-nvidia-open-hardened:latest]
    [flatpaks_file=/app/src/flatpaks.txt]
    [compression=squashfs]
    [selinux_contexts=/app/tmp.XvCBlebHSl/rootfs/etc/selinux/targeted/contexts/files/file_contexts]
    [extra_kargs=]
    [include_polkit=true]
    [include_livesys_scripts=true]
  clean
  init-work
  rootfs
    [image=ghcr.io/secureblue/kinoite-nvidia-open-hardened:latest]
  initramfs
  show-config
```
