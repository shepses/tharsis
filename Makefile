.ONESHELL:

# UID=$(shell id -u)
# GID=$(shell id -g)
# -v "./iso:/app" \
# --mount type=bind,src=./iso,target=/app \
# --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs \
# --userns=keep-id:uid=$(shell uid -u),gid=$(shell uid -g) \
# --cap-add CAP_CHOWN,CAP_DAC_OVERRIDE,CAP_FOWNER,CAP_FSETID,CAP_MKNOD,CAP_SETFCAP,CAP_SYS_ADMIN

PHONY: key
key:
	@gpg --batch --gen-key <<EOF
	%no-protection
	Key-Type: RSA
	Key-Length: 4096
	Name-Real: tharsis
	Name-Email: info@tharsis.eu
	Expire-Date: 10y
	%commit
	EOF

.PHONY: subids
subids:
	@usermod --add-subuids 100000-165535 $(whoami)
	@usermod --add-subgids 100000-165535 $(whoami)

.PHONY: images
images:
	cd images && sh build.sh && cd -

.PHONY: iso
CLEAN_WORKDIR="true"
iso:
	@podman run -it \
		--cap-add CAP_CHOWN,CAP_DAC_OVERRIDE,CAP_FOWNER,CAP_FSETID,CAP_MKNOD,CAP_SETFCAP,CAP_SYS_ADMIN \
		--userns=keep-id:uid=$(shell uid -u),gid=$(shell uid -g) \
		--env CLEAN_WORKDIR=$(CLEAN_WORKDIR) \
		--env HOOK_configure_livesys=/app/src/hooks/configure_livesys.sh \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock" \
		-v "./iso:/app" \
		-w /app \
		mkiso:latest \
		mkiso build
