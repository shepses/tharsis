#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2024 Universal Blue
# SPDX-FileCopyrightText: Copyright 2026 The Secureblue Authors
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

sed -i '/^install squashfs /d' /usr/lib/modprobe.d/secureblue.conf

# https://github.com/ublue-os/bazzite/issues/4126#issuecomment-3980175243
dnf remove -y google-noto-fonts-all homebrew bazaar
dnf install -y secureblue-logos
dnf reinstall -y polkit
dnf install -y anaconda-live firefox libblockdev-btrfs libblockdev-btrfs libblockdev-lvm libblockdev-dm

systemctl disable --global secureblue-flatpak-setup.service secureblue-flatpak-setup.timer podman-auto-update.timer flatpak-user-update.timer
systemctl disable rpm-ostreed-automatic.timer rpm-ostree-countme.service bootloader-update.service

rm -f /usr/share/applications/org.mozilla.Firefox.desktop /usr/share/applications/org.mozilla.firefox.desktop /usr/share/applications/firefox.desktop /usr/share/applications/firefox-wayland.desktop /usr/share/applications/firefox-x11.desktop

# add installer to kickoff
sed -i '/^Prepend=/s/$/;liveinst.desktop/' /usr/share/kde-settings/kde-profile/default/xdg/kicker-extra-favoritesrc || true

# Require the embedded installer image in containers-storage to satisfy the
# same sigstore policy used for registry pulls.
jq --arg image_ref "${include_image%%:*}" \
    '.transports["containers-storage"][""] =
    [
        {
            "type": "sigstoreSigned",
            "keyPaths": [
                "/usr/share/pki/containers/secureblue.pub",
                "/usr/share/pki/containers/secureblue-2025.pub"
            ],
            "signedIdentity": {
                "type": "exactRepository",
                "dockerRepository": $image_ref
            }
        }
    ]' /etc/containers/policy.json | tee /etc/containers/policy.json.tmp && mv /etc/containers/policy.json.tmp /etc/containers/policy.json

# FIX: disable signature verification for now. we will later do it with our own key 
# and re-sign images with `skopeo copy --sign-by` in `rootfs_include_container` step of `mkiso`.
cat <<EOF > /etc/containers/policy.json
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {}
}
EOF

# Disable suspend/sleep during live environment and initial setup
# This prevents the system from suspending during installation or first-boot user creation
cat > /usr/share/glib-2.0/schemas/zz3-secureblue-installer-power.gschema.override <<'EOF'
[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0

[org.gnome.desktop.session]
idle-delay=uint32 0
EOF

sed -i '/^UMASK[[:blank:]]/s/027/022/' /etc/login.defs

# don't autostart gnome-software session service
rm -f /etc/xdg/autostart/org.gnome.Software.desktop

# disable the gnome-software shell search provider
echo '
DefaultDisabled=true
' > /usr/share/gnome-shell/search-providers/org.gnome.Software-search-provider.ini


sed -i -e 's/ Fedora/ secureblue/' /usr/share/anaconda/gnome/fedora-welcome || true
sed -i -e 's/Fedora/secureblue/g' /usr/share/anaconda/gnome/org.fedoraproject.welcome-screen.desktop

cat > /etc/anaconda/profile.d/secureblue.conf <<'EOF'
# Anaconda configuration file for secureblue

[Profile]
profile_id = secureblue

[Profile Detection]
os_id = secureblue

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = fedora
menu_auto_hide = True

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1
default_partitioning =
    /     (min 1 GiB, max 70 GiB)
    /home (min 500 MiB, free 50 GiB)
    /var  (btrfs)

[User Interface]
custom_stylesheet = /usr/share/anaconda/pixmaps/silverblue/fedora-silverblue.css
hidden_spokes =
    NetworkSpoke
    PasswordSpoke
hidden_webui_pages =
    root-password
    network
password_policies =
        root (quality 100, length 15)
        user (quality 50, length 8)
        luks (quality 100, length 15)
EOF

# Fetch the Secureboot Public Key
EXPECTED_KEY_LOCATION="/app/src/certs/signing_pubkey.der"
if [ ! -f "$EXPECTED_KEY_LOCATION" ]; then
    echo "Secure boot key not found: $EXPECTED_KEY_LOCATION"
    exit 1
fi
cp "$EXPECTED_KEY_LOCATION" "$SIGNING_KEY_LOCATION"

# Enroll Secureboot Key
tee /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks <<EOF
%post --erroronfail --nochroot
set -oue pipefail

if [[ ! -d "/sys/firmware/efi" ]]; then
    echo "EFI mode not detected. Skipping key enrollment."
    exit 0
fi

if [[ ! -f "$SIGNING_KEY_LOCATION" ]]; then
    echo "Secure boot key not provided: $SIGNING_KEY_LOCATION"
    exit 0
fi

if grep -Eq 'Jupiter|Galileo' /sys/devices/virtual/dmi/id/product_name; then
    echo "Steam Deck hardware detected. Skipping key enrollment."
    exit 0
fi

mokutil --timeout -1 || true
echo -e "$KEY_ENROLLMENT_PASSWORD\n$KEY_ENROLLMENT_PASSWORD" | mokutil --import "$SIGNING_KEY_LOCATION" || true
%end
EOF

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${include_image} --transport=containers-storage
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF

# Signed Images
tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $include_image
%end
EOF

# enable xwayland
rm -f /etc/sway/config.d/99-noxwayland.conf /etc/systemd/user/org.gnome.Shell@user.service.d/override.conf /etc/systemd/user/plasma-kwin_wayland.service.d/override.conf

# hide root account creation in cockpit
cat >> /usr/share/cockpit/branding/fedora/branding.css << 'EOF'
.anaconda {
    .pf-v6-c-form__section:has(#anaconda-screen-accounts-root-account-enable-root-account) {
        /* Hide the whole section with "Enable root account". Might be not as reliable as it seems to be */
        display: none;
    }
}
EOF

# disable password strength labels
cat >> /usr/share/cockpit/branding/fedora/branding.css << 'EOF'
.anaconda {
    #disk-encryption-password-strength-label {
        display: none;
    }

    #anaconda-screen-accounts-create-account-password-strength-label {
        display: none;
    }
}
EOF

# Disable "ask an AI chatbot" in the context menu
mkdir -p /etc/firefox/policies
cat >> /etc/firefox/policies/policies.json << 'EOF'
{
  "policies": {
    "Preferences": {
      "browser.ml.chat.menu": { "Value": false, "Status": "locked" },
      "browser.ml.enable": { "Value": false, "Status": "locked" }
    }
  }
}
EOF
