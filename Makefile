.PHONY: images
images:
	@podman run -it \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock:Z" \
		-v "./images":/app \
		-w /app \
		podman:latest \
		sh /app/build.sh

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
		mkiso build \
			ghcr.io/secureblue/kinoite-nvidia-open-hardened:latest \
			/app/output.iso \
			tharsis_boot \
			localhost/ubuntu-bootc:latest
