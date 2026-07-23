# Tharsis
This repo contains the code for an upcoming operating system based on bootable containers and debian. It also employs a smart idea to do hierarchical `make` builds while gracefully avoiding nasty embeddings of shell code in Makefiles. See [makesh](https://github.com/shepses/makesh) for an introduction.

# usage:
- `./make.sh help`: Print usage
- `./make.sh ?`: List available build commands
- `./make.sh all`: Build everything
- `./make.sh images`: Build container images
- `./make.sh iso`: Build live iso
