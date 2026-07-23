init() {
    find . -maxdepth 3 -type f -name "*Containerfile" | while IFS= read -r cfile; do
        context=$(dirname "$cfile")
        cname=$(basename "$cfile")

        if [ "Containerfile" = "$cname" ]; then
            cname=$(basename "$context")
        fi

        podman build \
            --cap-add SYS_ADMIN,NET_ADMIN \
            --file "$cfile" \
            --tag "$cname:latest" \
            "$context" || return 1

        version=$(podman image inspect "$cname:latest" | jq -r '.[0].Labels["org.opencontainers.image.version"] // empty')

        if [ -n "$version" ]; then
            podman tag "$cname:latest" "$cname:$version"
        fi
    done
}
