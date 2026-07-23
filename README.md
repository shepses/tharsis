# Tharsis
This repo contains the code for an upcoming operating system based on bootable containers and debian.

# usage:
`make images`: 
```bash
.PHONY: images
images:
	cd images && sh build.sh && cd -
```

`make iso`: Remember to start podman socket first `systemctl start --user podman.socket`
```bash
.PHONY: iso
CLEAN_WORKDIR="true"
iso:
	@podman run -it \
		--privileged \
		--env CLEAN_WORKDIR=$(CLEAN_WORKDIR) \
		--env HOOK_post_rootfs=/app/src/hooks/prep_rootfs.sh \
		--env HOOK_pre_initramfs=/app/src/hooks/prep_initramfs.sh \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock" \
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
    [image=localhost/tharsis:latest]
    [iso_output_file=/app/tharsis.iso]
    [iso_disk_label=tharsis_boot]
    [include_image=localhost/tharsis:latest]
    [compression=squashfs]
    [selinux_contexts=/app/tmp/rootfs/etc/selinux/targeted/contexts/files/file_contexts]
    [extra_kargs=]
  clean
  show-config
```
