#!/bin/bash
set -euo pipefail

# 0. Drop in everything from system_files/ (skel configs, ocr-region, .justfile,
#    Terra repo + GPG key) — also includes the merged ghcr.io/ublue-os/brew files
#    from the Containerfile ctx stage (etc/profile.d/brew.sh,
#    usr/share/homebrew.tar.zst, brew-setup.service + update/upgrade timers)
cp -avf "/ctx/system_files"/. /

### Packages (Fedora + RPMfusion; LumineCapture from COPR — see below)
dnf5 -y install \
  ghostty btop just \
  gedit \
  nvim gcc make \
  grim tesseract wl-clipboard libnotify

### Umbriel + Noctalia (Terra repo, baked in via system_files/etc/yum.repos.d/terra.repo)
dnf5 -y install umbriel-nightly noctalia

### Noctalia Greeter (greetd) — replace GDM as the login screen
# greetd from Fedora, noctalia-greeter from Terra (baked in via system_files)
dnf5 -y install greetd noctalia-greeter

# Point greetd at the Noctalia greeter session wrapper (NOT the noctalia-greeter binary)
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greetd"
EOF

# Cut GDM over to greetd (Silverblue's default display manager is gdm).
# systemctl enable/disable are filesystem ops and work in the build container.
systemctl disable gdm
systemctl enable greetd

### Homebrew — enable first-boot setup + auto-update/upgrade timers
# The brew image ships these + a system-preset, but bootc install does NOT
# apply presets, so enable explicitly. (Bazzite/Bluefin only enable brew-setup;
# we also enable the update/upgrade timers for automatic Homebrew maintenance.)
systemctl enable brew-setup.service brew-update.timer brew-upgrade.timer

### Remove the GNOME login session (minimal: shell, session, gdm)
# Keep nautilus (file manager) + gedit (editor) + the GNOME *libraries*
# (gnome-keyring, gnome-desktop3/4, gnome-menus) that Noctalia/GTK still need.
# dnf also auto-drops the now-orphaned gnome-initial-setup (the first-boot
# "welcome center") and gnome-browser-connector. The `systemctl disable gdm`
# above already ran while gdm was present; removing the package is the clean cut.
dnf5 -y remove \
  gnome-shell gnome-shell-common \
  gnome-shell-extension-apps-menu gnome-shell-extension-background-logo gnome-shell-extension-common gnome-shell-extension-launch-new-instance gnome-shell-extension-places-menu gnome-shell-extension-window-list \
  gnome-session gnome-session-wayland-session gnome-classic-session \
  gdm

### Preinstall LazyVim plugins into the skel (headless sync; lazy-lock.json pins versions)
export HOME=/etc/skel
nvim --headless "+Lazy! sync" +qa

### Flatpak + Bazaar + DistroShelf (Flathub)
# DistroShelf = GUI for Distrobox "pet containers" (distrobox itself ships
# in the Silverblue base). /etc/distrobox/distrobox.ini (system_files) holds
# the declarative box list; the skel keyfile preselects Ghostty as the
# terminal it spawns into.
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --system flathub org.gnome.Loupe            # image viewer (crop/rotate/flip, EXIF/metadata)
flatpak install -y --system flathub io.github.kolunmi.Bazaar
flatpak install -y --system flathub com.ranfdev.DistroShelf
flatpak install -y --system flathub com.github.tchx84.Flatseal    # flatpak permission manager
flatpak install -y --system flathub io.github.flattool.Warehouse  # flatpak remote/override manager
flatpak install -y --system flathub it.mijorus.gearlever          # AppImage manager

### LumineCapture — screenshot/annotation tool (bound to Super+Print in the skel umbriel config)
# wlr-screencopy backend (same protocol as grim) — no portal needed.
# COPR: enable -> install -> disable (uBlue convention: COPRs left disabled in the image).
cat > /etc/yum.repos.d/lumine-capture.copr.repo <<'EOF'
[copr:copr.fedorainfracloud.org:netflate:lumine-capture]
name=Copr repo for lumine-capture owned by netflate
baseurl=https://download.copr.fedorainfracloud.org/results/netflate/lumine-capture/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/netflate/lumine-capture/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF
dnf5 -y install lumine-capture
# Leave the COPR disabled in the image (re-enable: dnf5 config-manager --set-enabled copr:copr.fedorainfracloud.org:netflate:lumine-capture)
sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/lumine-capture.copr.repo

dnf5 clean all
