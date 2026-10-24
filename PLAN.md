# Custom uBlue Image: Umbriel + Noctalia Desktop (v1)

Goal: build a custom uBlue/bootc image **on this machine** (Fedora 44 Workstation),
install it on **another machine**, and land on a desktop very similar to this laptop:
Umbriel + Noctalia, GNOME base apps (gedit, nautilus) with their defaults, Neovim 0.12
with the LazyVim setup, ghostty, btop, ocr-region, starship (on-demand via a baked
`just` recipe), Homebrew (baked via the official uBlue brew image — archive in the
image, first-boot service materializes it, see §5), and Flatpak with the Bazaar app
store preinstalled. Structured so "the more" can be
added in later rounds through the same mechanism — see `TUTORIAL.md` for how to
add/modify anything.

---

## 1. Findings (verified 2026-10-20)

### Build host (this machine)
- Fedora 44 Workstation (non-atomic), 16 cores / 62 GB RAM / 3.3 TB free — plenty.
- podman 5.8.9 (no docker; uBlue tooling is podman-native — fine).
- `just` **not installed** → `dnf install just` (only missing prerequisite).
- `/dev/kvm` + `qemu-system-x86_64` present → ISO can be VM-tested locally.
- `gh` CLI authenticated (mortalglitch) → optional GitHub/GHCR path available.

### Packages/config to replicate (from this machine)
| Item | State on this machine |
|---|---|
| Umbriel | `umbriel-nightly` 0.1.0-1.20261011 (Terra repo, id `terra`), `/usr/sbin/umbriel`, ships `start-umbriel` + `umbriel.desktop` wayland session |
| Noctalia | `noctalia` 5.3.0-1.fc44 (Terra), recommends ddcutil, gnome-keyring, upower |
| Neovim | nvim 0.12.5 + LazyVim: `~/.config/nvim` (init.lua, lua/config, lua/plugins, lazyvim.json, lazy-lock.json, matugen.lua) = 72 K; `~/.local/share/nvim/lazy` = 123 MB |
| gedit | only `~/.config/gedit/accels` (102 B) + dconf window-state |
| nautilus | empty `~/.config/nautilus` + dconf window-state |
| Umbriel config | `~/.config/umbriel/config.toml` + `noctalia.toml` |
| Noctalia state | `~/.local/state/noctalia/`: settings.toml (config_version 15, ui_scale 1.2, bar: clock/wallpaper/wallhaven + launcher/keys/workspaces, idle behaviors, lockscreen), `plugins/` (23 MB: materialized + git sources, community + official), `community-templates/` (1.4 MB) |

Terra repo (exact, from `/etc/yum.repos.d/terra.repo`, owned by `terra-release-44-10` +
`terra-gpg-keys-44-6`):
```
[terra]
name=Terra $releasever
metalink=https://tetsudou.fyralabs.com/metalink?repo=terra$releasever&arch=$basearch
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-terra$releasever
enabled=1
```

### Round-1 additions (verified 2026-10-20)
| Item | State on this machine |
|---|---|
| ghostty | `ghostty-1.3.1-4.fc44` (**Fedora rpm** → `dnf5 install ghostty`); config `~/.config/ghostty/` = `config.ghostty` (theme = noctalia) + `themes/noctalia`, 8 K; verified loading via `ghostty +show-config` |
| starship | `starship 1.27.0` via **Homebrew** (`/home/linuxbrew/.linuxbrew/bin/starship`); **not in Fedora repos** (`dnf5 repoquery starship` → 0); `~/.config/starship.toml` (187 lines); `.bashrc:28` = `eval "$(starship init bash)"` |
| btop | `btop-1.4.7-1.fc44` (**Fedora rpm**); config `~/.config/btop/` = `btop.conf` (color_theme = "noctalia") + `themes/` |
| ocr-region | `~/.local/bin/ocr-region`: `grim -s` (interactive selection + capture) → tesseract OCR → wl-copy → notify-send; deps all Fedora rpms: grim 1.5.0, tesseract 5.5.3, wl-clipboard 2.2.1, libnotify 0.8.8 (no hyprpicker/slurp — `grim -s` replaces the freeze+select dance) |

### Round-2 additions (verified 2026-10-20)
| Item | State on this machine |
|---|---|
| flatpak | `flatpak 1.18.4-1.fc44` (Fedora rpm); **verified inside the base image**: flatpak present, but `/var/lib/flatpak` does not exist — the remotes (`flathub` + `fedora` OCI, in `/var/lib/flatpak/repo/config` on the laptop) are local state, not image content → build.sh must add the flathub remote itself |
| Bazaar (`io.github.kolunmi.Bazaar` 0.9.9) | not installed here; **Flatpak app store** for discovering/installing Flathub apps (usebazaar.org); x86_64 available |
| Homebrew 7.0.10 | user-level at `/home/linuxbrew/.linuxbrew` (1.4 G), not package-owned | **baked via the official `ghcr.io/ublue-os/brew` image** (Bluefin pattern, verified locally): 158 MB — `/usr/share/homebrew.tar.zst` + `brew-setup.service` (first-boot extract → `/home/linuxbrew`, chown uid 1000) + `profile.d/brew.sh` shell integration + update/upgrade timers |
| other flatpak apps | 11 system flatpak apps installed (Lutris, Heroic, Zed, Discord, Flatseal, Gear Lever, Podman Desktop, LocalSend, ProtonPlus, Trayscale, Zen) — round-2 candidates |

### uBlue build system (researched)
- **`ublue-os/image-template`** (active; last commit 2026-10-12) — the sanctioned way to
  make custom bootc images:
  - `Containerfile`: `FROM ghcr.io/ublue-os/<base>` (template default `bazzite:stable`;
    we use **`silverblue-main:44`** — verified present on GHCR), then runs
    `build_files/build.sh` (bind-mounted at `/ctx`), then `bootc container lint`.
  - `system_files/` is copied into the image at `/` by the template's build.sh
    (`cp -avf /ctx/system_files/. /`) — so `system_files/etc/skel/...` → `/etc/skel/...`.
  - Justfile recipes: `just build` (podman), `just build-iso` / `rebuild-iso`
    (bootc-image-builder, `--type iso --rootfs=btrfs` → `output/bootiso/install.iso`),
    `just build-qcow2` + `systemd-vmspawn`, `just run-vm-iso` (qemu+KVM, web console).
  - `image-template.env`: IMAGE_NAME, REPO_ORGANIZATION, DEFAULT_TAG, …
  - Local build works without GitHub (a `git` repo is used only for the SHA label;
    a dirty tree is fine).
- **`ublue-os/titanoboa`** (active; May 2026) — fallback ISO maker:
  `sudo podman build --cap-add sys_admin --security-opt label=disable --squash -t <img> .`
  then `sudo ./main.sh` → Anaconda-based ISO in `output/`.
- Base images: `ghcr.io/ublue-os/silverblue-main:44` (GNOME) / `kinoite-main:44` (KDE), F44.
- **Verified inside `silverblue-main:44` (pulled 2026-10-20, 7.38 GB):** flatpak 1.18.4
  present; **no `/var/lib/flatpak`** (remotes not preconfigured); nautilus, GDM,
  gnome-shell present; **gedit and other GNOME apps (boxes, calculator, music) NOT
  installed** — uBlue strips them → `dnf5 install gedit` needed in build.sh.
- uBlue convention for third-party repos (from bazzite's Containerfile): enable → install →
  disable (COPRs). For Terra nightly we keep it enabled (harmless — bootc images don't
  dnf-update at runtime; updates come from image rebuilds).
- Per-user config on bootc: **`/etc/skel`** — copied into new users' homes at install time
  (bootc install creates the user via useradd). System-wide dconf defaults would be
  `gschema.override` files under `/usr/share/glib-2.0/schemas/` (bazzite pattern) — but our
  gedit/nautilus dconf content is window-state only, so nothing to override.

---

## 2. Architecture

```
~/AI Work/ublue-custom-image/            (local git repo; git init required)
├── Containerfile                        FROM ghcr.io/ublue-os/brew:latest AS brew
│                                          (ctx merge — Homebrew, see §5)
│                                          FROM ghcr.io/ublue-os/silverblue-main:44
├── Justfile                             (from image-template)
├── image-template.env                   IMAGE_NAME=verdant-linux, REPO_ORGANIZATION=local, …
├── build_files/
│   └── build.sh                         terra repo + packages + LazyVim preinstall
├── system_files/                        (copied to / in the image)
│   ├── etc/skel/.config/nvim/           init.lua, lua/, lazyvim.json, lazy-lock.json, matugen.lua
│   ├── etc/skel/.config/umbriel/        config.toml, noctalia.toml
│   ├── etc/skel/.config/gedit/accels
│   ├── etc/skel/.config/ghostty/        config.ghostty, themes/noctalia
│   ├── etc/skel/.config/starship.toml   187-line powerline config
│   ├── etc/skel/.config/btop/           btop.conf (noctalia theme), themes/
│   ├── etc/skel/.local/state/noctalia/  settings.toml, state.toml, plugins/, community-templates/
│   ├── etc/skel/.local/bin/ocr-region   region OCR → clipboard script
│   └── etc/skel/.justfile               on-demand recipes (starship, brew; future tools)
└── disk_config/iso.toml                 bootc-image-builder ISO config
```

Build flow (all on this machine):
1. `dnf install just`
2. `just build` → `localhost/verdant-linux:<tag>` (pulls silverblue-main:44, ~2 GB)
3. `just build-iso` → `output/bootiso/install.iso` (expect ~3 GB)
4. Test in VM: `just run-vm-iso` (KVM present) or qcow2 + `systemd-vmspawn`
5. Burn ISO to USB → install on target machine (x86_64, UEFI)

> **`TUTORIAL.md` (this directory)** — small how-to for adding/modifying anything in the
> build: packages, dotfiles, scripts, on-demand just recipes, base image, rebuild loop.

---

## 3. `build_files/build.sh` (v1)

```bash
#!/bin/bash
set -euo pipefail

# Template step: custom system files -> /
# (system_files also includes the merged ghcr.io/ublue-os/brew files from the
#  Containerfile ctx stage: etc/profile.d/brew.sh, usr/share/homebrew.tar.zst,
#  brew-setup.service + update/upgrade timers — nothing to do here)
cp -avf "/ctx/system_files"/. /

# --- Terra repo (Umbriel + Noctalia) ---
# Install the repo definition + GPG keys first (nogpgcheck only for the bootstrap install)
dnf5 -y install --nogpgcheck \
    --repofrompath terra,https://tetsudou.fyralabs.com/terra44 \
    terra-release terra-gpg-keys
# Now the repo is properly configured/verified:
dnf5 -y install umbriel-nightly noctalia

# --- ghostty, btop, just, + ocr-region deps (all Fedora repos) ---
# (gedit: NOT in the silverblue base — verified in the image — install explicitly)
dnf5 -y install ghostty btop just gedit
dnf5 -y install grim tesseract wl-clipboard libnotify

# --- flatpak + Bazaar app store ---
# flatpak ships in the silverblue base (verify; this is a no-op if so)
dnf5 -y install flatpak
# ensure flathub remote exists (uBlue images usually preconfigure it with their
# filter — only add the stock remote if it's missing)
flatpak remote-list --system | grep -q flathub || flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/
# Bazaar: Flatpak app store (io.github.kolunmi.Bazaar)
flatpak install -y --system flathub io.github.kolunmi.Bazaar

# --- Neovim + LazyVim: preinstall plugins so the target works offline ---
# /etc/skel/.config/nvim already exists (copied above); let Lazy write into skel:
export HOME=/etc/skel
nvim --headless "+Lazy! sync" +qa     # respects lazy-lock.json pins -> /etc/skel/.local/share/nvim/lazy
nvim --headless "+TSUpdate" +qa || true   # pre-download treesitter parsers (best effort)
unset HOME
```

Notes:
- `Lazy! sync` is pinned by `lazy-lock.json` → reproducible plugin set.
- Mason tooling downloads happen at first use (needs network then) — acceptable.
- Umbriel can't run in the build container (no Wayland); config is validated on this
  machine (`umbriel config validate`) before baking, and in the VM after install.

---

## 4. Baked-in inventory (v1)

| Item | Source (this machine) | Destination in image |
|---|---|---|
| Umbriel + Noctalia (+ ddcutil, gnome-keyring, upower) | Terra repo | system (dnf5 install) |
| Umbriel config | `~/.config/umbriel/{config.toml,noctalia.toml}` | `/etc/skel/.config/umbriel/` |
| Noctalia settings | `~/.local/state/noctalia/settings.toml`, `state.toml` | `/etc/skel/.local/state/noctalia/` |
| Noctalia plugins (23 MB) | `~/.local/state/noctalia/plugins/` | `/etc/skel/.local/state/noctalia/plugins/` |
| Noctalia community templates (1.4 MB) | `~/.local/state/noctalia/community-templates/` | `/etc/skel/.local/state/noctalia/` |
| LazyVim config (72 K) | `~/.config/nvim/` | `/etc/skel/.config/nvim/` |
| LazyVim plugins (~123 MB) | built at image build time (`Lazy! sync`) | `/etc/skel/.local/share/nvim/lazy/` |
| ghostty 1.3.1 | Fedora rpm + `~/.config/ghostty/` (noctalia theme) | system (dnf5) + `/etc/skel/.config/ghostty/` |
| starship 1.27.0 | Homebrew here; **not in Fedora repos** | `/etc/skel/.justfile` recipe `just starship` (brew or pinned release download) + `.bashrc` init line; config baked via skel |
| btop 1.4.7 | Fedora rpm + `~/.config/btop/` (noctalia theme) | system (dnf5) + `/etc/skel/.config/btop/` |
| ocr-region | `~/.local/bin/ocr-region` + grim/tesseract/wl-clipboard/libnotify | `/etc/skel/.local/bin/ocr-region` + system (dnf5) |
| flatpak 1.18.x | (ships in silverblue base — verify at build; `dnf5 install flatpak` is a no-op if so) | system; remotes in image `/var/lib/flatpak/repo/config` |
| Bazaar 0.9.9 | `io.github.kolunmi.Bazaar` from Flathub | installed at build time (`flatpak install --system`; `/var/lib/flatpak` carries into the installed system's `/var` subvolume) |
| Homebrew (bundled version) | `ghcr.io/ublue-os/brew` image: tarball + `brew-setup.service` + profile.d + timers | system (baked archive + first-boot service) |
| just | (also needed on build host; on target it runs the .justfile recipes) | system (dnf5) |
| gedit shortcuts | `~/.config/gedit/accels` | `/etc/skel/.config/gedit/accels` |
| gedit/nautilus defaults | dconf = window-state only | stock behavior (documented; no overrides) |
| GNOME desktop, GDM, nautilus | `silverblue-main:44` base | system |
| gedit 50.0 | Fedora repo — **not in the silverblue base** (verified in image) | system (dnf5) |
| nvim 0.12 | Fedora 44 | system |

---

## 5. On-demand extras (baked `just` recipes)
Tools that should be *available* rather than *installed* (starship isn't in Fedora repos)
get a recipe in `system_files/etc/skel/.justfile` → `~/.justfile` (`just` is installed in
build.sh; running `just` from the home dir discovers the file).

v1 recipe — `just starship`:
```just
starship:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v starship >/dev/null; then
      if command -v brew >/dev/null; then
        brew install starship                      # same source as this laptop
      else
        ver="1.27.0"; arch="x86_64-unknown-linux-musl"
        mkdir -p "${HOME}/.local/bin"
        curl -fsSL "https://github.com/starship-cli/starship/releases/download/v${ver}/starship-${ver}-${arch}.tar.gz" \
          | tar -xz -C "${HOME}/.local/bin" --strip-components=1 "starship-${ver}-${arch}/starship"
      fi
    fi
    grep -q 'HOME/.local/bin' "${HOME}/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
    grep -q 'starship init bash' "${HOME}/.bashrc" || echo 'eval "$(starship init bash)"' >> "${HOME}/.bashrc"
    echo "starship ready — open a new shell (or: source ~/.bashrc)"
```
- Uses Homebrew if present (your laptop's path); otherwise downloads the exact release
  artifact brew installs (pinned 1.27.0 = this laptop's version).
- Appends the same `.bashrc` line your laptop has (`.bashrc:28`), idempotently.
- `~/.config/starship.toml` is baked via skel, so `just starship` is the only step.
- This is the pattern for any future on-demand tool (TUTORIAL.md §4).

**Homebrew — baked (Bluefin pattern).** The *deployed* brew tree can't live in the
image (the `/home` subvolume is created fresh at install, hiding any image `/home`
content), but the **archive + setup service** can. The official `ghcr.io/ublue-os/brew`
image (158 MB, verified locally) carries:
- `/usr/share/homebrew.tar.zst` — the Homebrew tree (6,036 files)
- `brew-setup.service` — oneshot, enabled via system-preset; at first boot extracts the
  tarball to `/home/linuxbrew/.linuxbrew` and chowns it to uid 1000 (the installed
  user). `ConditionPathExists` guards mean it never re-runs or clobbers a live install.
- `etc/profile.d/brew.sh` — system-wide shell integration for all users (appends brew
  to PATH *after* system dirs, so it can't shadow dbus & co.)
- `brew-update.timer` / `brew-upgrade.timer` — keep Homebrew and formulae current
- `etc/security/limits.d/30-brew-limits.conf` — nofile bump to 4096

Wiring is the two ctx-stage lines in §2 — build.sh's existing
`cp -avf /ctx/system_files/. /` places the merged files. Result: `brew` works in a new
shell right after first boot — no network, no sudo, no installer script.

A `just brew` fallback recipe (official installer script, idempotent) stays in the
`.justfile` for the case where `/home` was wiped and the service can't re-run:

```just
brew:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v brew >/dev/null; then
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    grep -q 'linuxbrew' "${HOME}/.bashrc" || echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${HOME}/.bashrc"
    echo "brew ready — open a new shell (or: source ~/.bashrc)"
```

After first boot, `brew install starship` becomes the starship recipe's preferred path
(it already prefers brew when present).

## 6. Target machine first-boot experience
- GDM (from silverblue) → session menu → **Umbriel** (session file shipped by
  `umbriel-nightly`) → Noctalia auto-starts (Noctalia-informed session).
- The installer-created user receives all skel dotfiles.
- First `nvim`: LazyVim loads from baked `lazy/` (offline-capable); treesitter/mason may
  fetch small updates if online.
- `state.toml` references display `eDP-1` (this laptop) — Noctalia reconciles
  per-display at runtime; harmless on different hardware.
- Bazaar (Flatpak app store) is already installed; more flatpak apps can be added via
  Bazaar or `flatpak install` at first boot.
- Homebrew is ready automatically: `brew-setup.service` extracted the baked archive to
  `/home/linuxbrew/.linuxbrew` (owned by the user); a new shell has `brew` on PATH via
  `/etc/profile.d/brew.sh`. Verify: `systemctl status brew-setup.service`,
  `brew --version`.

---

## 7. Updates story (post-install)
Bootc images update by **rebasing to a new image tag**, not dnf.
- **v1 (local):** rebuild here (`just build && just build-iso`), re-burn/reinstall; or
  `podman save` + `bootc switch` from the local image.
- **v2 (optional, recommended later):** push this repo to GitHub (gh CLI already
  authenticated) + enable the template's GH Actions → GHCR image + ISO artifacts; on the
  target, `uupd` rebases to the latest custom tag. Umbriel is nightly → rebuild whenever
  you want the latest.

---

## 8. Risks / pitfalls
- `just` missing on this machine → `dnf install just` (only prerequisite gap).
- First build is slow: ~2 GB base pull + build + ISO → 30–60 min on this box.
- Noctalia plugin `sources/` are git checkouts inside the 23 MB — bake as-is; Noctalia
  reconciles on first run. (Size-lean alternative: bake only `materialized/` + settings,
  let Noctalia re-clone sources at first run — needs network.)
- Treesitter/mason: build-time preinstall covers most; a few first-run downloads possible.
- **Target must be x86_64 + UEFI** (uBlue custom images are x86_64) — confirm before
  finalizing.
- Secure Boot: ostree/uBlue ISOs ship shim; expected fine, verify on target.
- silverblue includes the core GNOME stack (nautilus, GDM, gnome-shell, dconf) but
  **not the extra GNOME apps** (gedit etc. — verified missing in the image); build.sh
  installs gedit explicitly. A leaner `fedora-bootc:44` + cherry-picked apps is
  possible but not recommended for v1.
- `just build` wants a git repo (SHA label) → `git init` + initial commit.
- Nightly drift: umbriel-nightly is pinned to build time; rebuild picks up latest —
  VM-test every ISO before burning (nightly compositor can break).

---

## 9. Verification plan (must pass before shipping)
1. `just build` succeeds; `bootc container lint` passes (built into template); labels sane.
2. `just build-iso` produces `output/bootiso/install.iso`.
3. VM boot (KVM):
   - GDM appears; **Umbriel** in the session list.
   - Login → Noctalia shell with baked bar layout (clock/wallpaper/wallhaven,
     launcher/keys/workspaces), ui_scale 1.2.
   - `nvim` → LazyVim loads with plugins present (no re-download storm).
   - gedit + nautilus launch and behave stock.
   - `umbriel config validate` inside the VM.
   - ghostty opens with the noctalia theme; btop opens with the noctalia theme.
   - `ocr-region` OCRs a drawn region into the clipboard (notify-send confirms).
   - `just starship` installs starship; a new shell shows the starship prompt.
   - `flatpak list` shows Bazaar (`io.github.kolunmi.Bazaar`); it opens from the app grid
     and lists Flathub apps.
   - `brew --version` works in a new shell with no manual steps (baked archive +
     `brew-setup.service`); `systemctl status brew-setup.service` shows it ran once.
     Fallback: `just brew` reinstalls from the official script if /home was wiped.
   - Optional deeper test: `bootc install` into a qcow2 → first-boot user has skel files.
     (Also confirms `/var/lib/flatpak` — Bazaar + remotes — survives install.)
4. Ship ISO + sha256sum.

---

## 10. Round-2 candidates (the "there's more")
All present on this machine; each is just more `system_files/` content:
- kitty, nwg-panel, ibus, hypr (if Hyprland wanted too),
  libreoffice config, gtk-3.0/gtk-4.0 themes
- `~/.local/bin`: hermes*, simplex-chat
- (ghostty, starship, btop, ocr-region moved into v1)
- The laptop's other 11 flatpak apps (Lutris, Heroic, Zed, Discord, Flatseal, Gear Lever,
  Podman Desktop, LocalSend, ProtonPlus, Trayscale, Zen) — same build-time `flatpak
  install --system` pattern as Bazaar (~12 G locally; pick a subset)
- `mimeapps.list`, `autostart/`, gh config
- Full `dconf dump /` → `gschema.override` for anything beyond window-state
- systemd user services (simplex-chat daemon etc.)

---

## 11. Open decisions (recommendations in **bold**)
1. Base image: **`silverblue-main:44` (GNOME)** — matches gedit/nautilus/Workstation
   laptop; alternative `kinoite-main:44` (KDE).
2. Hosting: **local-only build for v1** (matches "build on the current machine");
   GitHub + GHCR later for `uupd`-style updates.
3. Noctalia plugins: **bake all 23 MB** (offline-complete).
4. Terra repo in image: **leave enabled** (nightly; no runtime dnf on bootc anyway).
5. Image name/tag: `localhost/verdant-linux:44` (named "Verdant Linux" 2026-10-24).
6. starship: **on-demand `just starship` recipe** (brew if present, else pinned official
   release) since it's not in Fedora repos; `starship.toml` baked via skel.
