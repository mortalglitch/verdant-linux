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

### NTP — enable systemd-timesyncd (the uBlue base ships it UNENABLED)
# The timesyncd binary is in the base (merged into systemd-udev in Fedora 44 —
# there is no standalone systemd-timesyncd package), but the service is not
# enabled. Without an NTP client running, an offline install leaves the system
# clock unsynced and nothing corrects it once the machine goes online — TLS
# cert validation against Flathub/Bazaar then fails on the bad timestamp.
# Enabling it makes the clock sync itself the moment a network is up.
systemctl enable systemd-timesyncd.service

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

### Branding — Verdant (os-release + Noctalia Greeter)
# os-release NAME/PRETTY_NAME drive three things: the installer welcome screen
# and GRUB menu (bootc-image-builder bakes this into .buildstamp at ISO build
# time) and the installed system's release strings. ID=fedora stays — repos
# and tooling key off it, not NAME.
sed -i -E \
  -e 's/^NAME=.*/NAME="Verdant"/' \
  -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Verdant"/' \
  /etc/os-release

# Noctalia Greeter: static admin config (wins over Noctalia Sync — the sync UI
# lives in Noctalia Shell, so a static toml is the reliable route for a
# locked-in login screen). Verdant palette (dark variant of the skel
# VerdantBrutalistTheme.json), star-trails wallpaper, Umbriel as the default
# session, Noctalia logo hidden (we're Verdant, not Noctalia).
install -d /usr/share/verdant
install -m 644 /etc/skel/Pictures/Wallpapers/star-trails-dark.png /usr/share/verdant/wallpaper.png
mkdir -p /var/lib/noctalia-greeter
cat > /var/lib/noctalia-greeter/greeter.toml <<'EOF'
[session]
default = "Umbriel"

[appearance]
scheme = "Synced"
theme_mode = "dark"
hide_logo = true
power_buttons_position = "bottom-right"

[appearance.palette]
primary = "#9CAF88"
on_primary = "#24231F"
secondary = "#9DB8A6"
on_secondary = "#24231F"
tertiary = "#C97B54"
on_tertiary = "#24231F"
error = "#C75146"
on_error = "#F5F2E9"
surface = "#24231F"
on_surface = "#E8E4D9"
surface_variant = "#3A3931"
on_surface_variant = "#B8B2A0"
outline = "#6E6A5C"
shadow = "#1B1A16"
hover = "#403F35"
on_hover = "#E8E4D9"

[appearance.wallpaper]
path = "/usr/share/verdant/wallpaper.png"
fill_mode = "crop"
fill_color = "#1B1A16"
EOF
chown -R greetd:greetd /var/lib/noctalia-greeter

### Firewall — custom 'verdant' zone (public-style, no SSH), default zone
# Fedora's default FedoraWorkstation zone opens SSH and every port >1024, and
# even the stock 'public' zone allows ssh. Ship a custom zone = public minus
# ssh, and make it the default. openssh-server stays installed but disabled;
# ~/.config/verdant/ssh.just (wrapper: `just ssh <enable|disable|status>`)
# flips SSH on/off in the default zone.
mkdir -p /etc/firewalld/zones
cat > /etc/firewalld/zones/verdant.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Verdant</short>
  <description>Verdant default: public-style zone with SSH removed. Enable SSH with: just ssh enable</description>
  <service name="mdns"/>
  <service name="dhcpv6-client"/>
  <forward/>
</zone>
EOF
sed -i 's/^DefaultZone=.*/DefaultZone=verdant/' /etc/firewalld/firewalld.conf

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
