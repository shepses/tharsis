init() {
	podman run -it \
		--privileged \
		--env-file <(printf '%s\n' "$@") \
		--env HOOK_configure_livesys=/app/src/hooks/configure_livesys.sh \
		--env CONTAINER_HOST=unix:///var/run/podman.sock \
		-v "${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/podman.sock" \
		-v "./:/app" \
		-w /app \
		mklive:latest \
		mklive build
}
