# Tharsis
This repo contains the code for an upcoming operating system based on bootable containers and debian.

# usage:
`make images`: 
```bash
.PHONY: images
images:
	@find -maxdepth 3 -type f -name Containerfile -exec dirname {} \; | while IFS= read container; do \
		name=$$(basename "$$container"); \
		if [ -f "$$container/VERSION" ]; then \
			version=$$(head -n 1 "$$container/VERSION"); \
		else \
			version=""; \
		fi; \
		if [ -z "$$version" ]; then \
			echo "No version tag in $$container/VERSION"; \
			exit 1; \
		fi; \
		podman build \
			--cap-add SYS_ADMIN,NET_ADMIN \
			--file "$$container/Containerfile" \
			--tag "$$name:$$version" \
			--tag "$$name:latest" \
			"$$container" || exit 1; \
	done
```

`make iso`: Remember to start podman socket first `systemctl start --user podman.socket`
```bash
.PHONY: iso
CLEAN_WORKDIR="true"
iso:
	@podman run -it \
		--privileged \
		--env CLEAN_WORKDIR=$(CLEAN_WORKDIR) \
		--env HOOK_configure_livesys=/app/src/hooks/configure_livesys.sh \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock" \
		-v "./:/app" \
		-w /app \
		mklive:latest \
		mklive build
```

`podman run mklive:latest`: 
```bash
Usage: /usr/local/bin/mklive [command] [args...]
Commands:
  build
    [image=tharsis:latest]
    [iso_output_file=/app/tharsis.iso]
    [iso_disk_label=tharsis_boot]
    [include_image=tharsis:latest]
    [extra_kargs=]
  clean
  show-config
  extract
    [image=tharsis:latest]
  include
    [image=tharsis:latest]
  install
  squash
  iso
    [iso_output_file=/app/tharsis.iso]
    [iso_disk_label=tharsis_boot]
    [extra_kargs=]

```
