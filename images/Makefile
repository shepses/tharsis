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
