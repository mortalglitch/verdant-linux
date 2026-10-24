#!/bin/bash
set -euo pipefail

# 0. Drop in everything from system_files/ (skel configs, ocr-region, .justfile,
#    Terra repo + GPG key) — also includes the merged ghcr.io/ublue-os/brew files
#    from the Containerfile ctx stage (etc/profile.d/brew.sh,
#    usr/share/homebrew.tar.zst, brew-setup.service + update/upgrade timers)
cp -avf "/ctx/system_files"/. /

### Packages (Fedora + RPMfusion — no COPRs needed)
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
[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greeter"
EOF

# Cut GDM over to greetd (Silverblue's default display manager is gdm).
# systemctl enable/disable are filesystem ops and work in the build container.
systemctl disable gdm
systemctl enable greetd

### Preinstall LazyVim plugins into the skel (headless sync; lazy-lock.json pins versions)
export HOME=/etc/skel
nvim --headless "+Lazy! sync" +qa

### Flatpak + Bazaar (Flathub)
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --system flathub io.github.kolunmi.Bazaar

dnf5 clean all
