FROM scratch AS vendor

COPY vendor/. /vendor

FROM docker.io/library/debian:trixie AS base

FROM base AS builder

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt update -y && \
    DEBIAN_FRONTEND=noninteractive apt install -y git curl make build-essential go-md2man \
    libzstd-dev pkgconf dracut autoconf libtool gtk-doc-tools libglib2.0-dev libgpgme-dev bison liblzma-dev \
    libext2fs-dev libfuse3-dev libssl-dev libsoup-3.0-dev libcurl4-openssl-dev

RUN --mount=type=bind,from=vendor,source=/vendor,target=/vendor,rw \
    cd /vendor/libostree && \
    NOCONFIGURE=1 ./autogen.sh && \
    ./configure --with-curl --prefix=/usr --sysconfdir=/etc --libdir=/lib/$(gcc -print-multiarch) && \
    make && make install DESTDIR=/dist/libostree && \
    cp -r /dist/libostree/lib/. /usr/lib/ && \
    cp -r /dist/libostree/usr/. /usr/ && \
    cp -r /dist/libostree/etc/. /etc/

RUN apt install -y equivs
RUN printf 'Section: libs\n\
Priority: optional\n\
Package: libostree-1-1\n\
Version: 2025.3\n\
Maintainer: Tharsis <info@tharsis.eu>\n\
Architecture: amd64\n\
Description: Placeholder package for compiled libostree 2025.3\n' > /dist/libostree/libostree.control && \
printf 'Section: libs\n\
Priority: optional\n\
Package: libostree-dev\n\
Version: 2025.3\n\
Maintainer: Tharsis <info@tharsis.eu>\n\
Architecture: amd64\n\
Description: Placeholder package for headers of libostree 2025.3\n' > /dist/libostree/libostree-dev.control && \
cd /dist/libostree && equivs-build libostree.control && equivs-build libostree-dev.control

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
WORKDIR /home/build
RUN curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    git clone "https://github.com/bootc-dev/bootc.git" . && \
    sh -c ". ${RUSTUP_HOME}/env; make bin install-all DESTDIR=/dist/bootc"

FROM base AS system

RUN rm /etc/apt/sources.list.d/debian.sources && \
    echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian trixie-updates main" >> /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian-security trixie-security main" >> /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian trixie-backports main" >> /etc/apt/sources.list && \
    apt update

# Install bootc os tools
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
  DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y btrfs-progs bubblewrap dosfstools e2fsprogs fdisk dracut \
    firmware-linux-free linux-image-generic netplan.io libnss-resolve libnss-myhostname openssh-server \
    skopeo podman fuse-overlayfs systemd systemd-boot* systemd-resolved xfsprogs && \
  cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz" && \
  apt clean -y

COPY src/etc/netplan/ /etc/netplan/

RUN systemctl enable systemd-networkd systemd-resolved ssh && \
    printf 'L! /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n' \
        > /usr/lib/tmpfiles.d/resolv-conf.conf && \
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config || true

COPY --from=builder /dist/bootc/. /

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    mkdir -p /usr/lib/dracut/dracut.conf.d/ && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | \
        tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc "' | \
        tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    KERNELVERSION=$(basename "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n 1)") && \
    dracut --force "/usr/lib/modules/${KERNELVERSION}/initramfs.img" "${KERNELVERSION}"

COPY --from=builder /dist/libostree/lib/. /usr/lib/ 
COPY --from=builder /dist/libostree/usr/. /usr/
COPY --from=builder /dist/libostree/etc/. /etc/
COPY --from=builder /dist//libostree/*.deb /tmp/

RUN dpkg -i /tmp/*.deb && rm /tmp/*.deb

RUN DEBIAN_FRONTEND=noninteractive apt install -y kde-standard libqt5core5a sddm locales

COPY src/flatpaks.txt /tmp/flatpaks.txt
RUN DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y flatpak libcurl4 ca-certificates && \
    chmod u+s /usr/bin/bwrap && \
    mkdir -p /etc/flatpak/installations.d/ && \
    echo "[Installation \"bootc\"]\nPath=/usr/lib/flatpak\nDisplayName=System Flatpaks\nStorageType=hard-assoc\nReadOnly=true" \
        > /etc/flatpak/installations.d/bootc.conf && \
    flatpak remote-add --installation=bootc flathub https://dl.flathub.org/repo/flathub.flatpakrepo && \
    grep -v "#.*" /tmp/flatpaks.txt | xargs "-i{}" -d "\n" sh -c "flatpak install --installation=bootc --noninteractive -y {}" && \
    chmod u-s /usr/bin/bwrap

RUN DEBIAN_FRONTEND=noninteractive apt install --no-install-recommends -y curl wget rsync openssh-client jq yq emacs-nox vim

# Install Wifi drivers
# NOTE: Firmwares are unfortunately non-free
RUN sed -i '1c\deb http://deb.debian.org/debian trixie main non-free-firmware' /etc/apt/sources.list && apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y network-manager-iwd firmware-linux firmware-iwlwifi firmware-realtek && \
    sed -i '1c\deb http://deb.debian.org/debian trixie main' /etc/apt/sources.list

RUN systemctl set-default graphical.target && systemctl enable sddm

COPY <<EOF /etc/containers/storage.conf
[storage]
driver = "vfs"
graphroot = "/var/lib/containers/storage"
runroot = "/var/run/containers/storage"
EOF

RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /boot /root /home /usr/local /srv /opt /mnt /var /run/* /tmp/* /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    rm -f /initrd.img /initrd.img.old /vmlinuz /vmlinuz.old && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && \
    ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && \
    ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | \
        tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | \
        tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | \
        tee "/usr/lib/ostree/prepare-root.conf"

LABEL containers.bootc 1

RUN bootc container lint

# VERSION: 1.0.0