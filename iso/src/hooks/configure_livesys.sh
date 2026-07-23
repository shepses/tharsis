#!/usr/bin/env bash

set -euo pipefail

############################################################################
## host/root
echo "$HOSTNAME_LIVESYS" > /etc/hostname
passwd -d root
cp $SRC_ROOT/etc/pam.d/* /etc/pam.d/
rm -f /etc/xdg/autostart/calamares-desktop-icon.desktop
mkdir -p /etc/sddm.conf.d
cp $SRC_ROOT/etc/sddm.conf.d/* /etc/sddm.conf.d/

############################################################################
## live user
groupadd -r nopasswdlogin || true
useradd -m -s /bin/bash live || true
passwd -d live
usermod -aG sudo,video,audio,render,input,cdrom,plugdev,nopasswdlogin live
mkdir -p /etc/sudoers.d
echo "live ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/live
chmod 0440 /etc/sudoers.d/live
mkdir -p /home/live/Desktop
cat > /home/live/Desktop/install-tharsis.desktop <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Install Tharsis
Comment=Install Tharsis to disk
Exec=sudo pkexec calamares
Icon=system-software-install
Terminal=false
Categories=System
EOF
chmod +x /home/live/Desktop/install-tharsis.desktop
gio trust /home/live/Desktop/install-tharsis.desktop 2>/dev/null || true
mkdir -p /home/live/.config/
cp $SRC_ROOT/liveuser/config/* /home/live/.config/
chown -R live:live /home/live

############################################################################
## calamares installer
cp $SRC_ROOT/etc/calamares/settings.conf /etc/calamares/settings.conf
cp $SRC_ROOT/etc/calamares/modules/* /etc/calamares/modules

