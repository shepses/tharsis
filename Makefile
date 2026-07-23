SUBDIRS := images iso
.DEFAULT_GOAL := images

# UID=$(shell id -u)
# GID=$(shell id -g)
# -v "./iso:/app" \
# --mount type=bind,src=./iso,target=/app \
# --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs \
# --userns=keep-id:uid=$(UID,gid=$(GID) \
# --cap-add CAP_CHOWN,CAP_DAC_OVERRIDE,CAP_FOWNER,CAP_FSETID,CAP_MKNOD,CAP_SETFCAP,CAP_SYS_ADMIN

.PHONY: all $(SUBDIRS)

all: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@

