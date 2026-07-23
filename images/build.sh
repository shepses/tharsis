#!/bin/bash

for dir in tools os; do
	for containerfile in $(find $dir -name "*.Containerfile"); do
	  name="$(basename ${containerfile} .Containerfile)"
	  version=$(tail -2 $containerfile | grep "# VERSION:" | cut -d: -f2 | awk '{$1=$1;print}')
	  [ ! -z "${version}" ] || (echo "No version tag in $containerfile" && exit 1)
	  podman build \
	  	--cap-add=SYS_ADMIN,NET_ADMIN \
		--security-opt seccomp=unconfined \
	    --file $containerfile \
	    --tag "${name}:${version}" --tag "${name}:latest" \
	    $(dirname $containerfile) || exit 1
	done
done
