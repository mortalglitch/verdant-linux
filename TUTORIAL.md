# Tutorial: adding & modifying what's in the build

Everything that ends up in the image lives in a few well-defined places. Know those
and you can change anything.

## Repo map

| Where | Lands in the image as | Use for |
|---|---|---|
| `build_files/build.sh` | (runs at build time) | packages, repo setup, build-time steps (e.g. LazyVim preinstall) |
| `system_files/<path>` | `/<path>` | everything else: configs, skel dotfiles, scripts, units |
| `Containerfile` | — | base image choice + build-time RUN steps |
| `Justfile`, `image-template.env` | — | build automation, image name/tags |

The workhorse is `system_files/`: build.sh starts with
`cp -avf /ctx/system_files/. /` — whatever you put under `system_files/` is copied
verbatim into the image root.

## 1. Add a package (dnf)
In `build_files/build.sh`, next to the other installs:
```bash
dnf5 -y install some-package
```
- Fedora/RPMFusion: plain `dnf5 install`.
- COPR:
  ```bash
  dnf5 -y copr enable owner/repo
  dnf5 -y install some-package
  dnf5 -y copr disable owner/repo   # uBlue convention: leave COPRs disabled in the image
  ```
- Third-party repo (Terra pattern): install the repo-definition rpm first
  (`--repofrompath` bootstrap), then install normally — see the Terra block in build.sh.
  Note: `system_files/etc/dnf/repos.override.d/terra-gpgcheck.repo` relaxes
  `gpgcheck` for the Terra repo because bootc-image-builder's manifest step
  can't read the baked `file://` GPG key (Terra has no https key URL). Packages
  are still GPG-verified during the container build. Remove that override file
  if you want strict checking back.

## 2. Add a config file / dotfile
Copy it into the skel tree so the installed user gets it in their home:
```bash
mkdir -p system_files/etc/skel/.config/thing
cp ~/.config/thing/config.toml system_files/etc/skel/.config/thing/
```
`/etc/skel` is copied into new users' homes at install time, so
`system_files/etc/skel/<x>` → `/etc/skel/<x>` → `~user/<x>`.

System-wide (non-per-user) files go directly under `system_files/`, e.g.
`system_files/usr/share/...`. (Files under `/usr/etc` are OSTree config templates —
preserved across updates; use those for things you want the user to be able to edit.)

## 3. Add a script / standalone binary
```bash
mkdir -p system_files/etc/skel/.local/bin
cp ~/.local/bin/ocr-region system_files/etc/skel/.local/bin/
chmod +x system_files/etc/skel/.local/bin/ocr-region
```
Then add its runtime deps to build.sh. Find package names for any command the script
uses: `rpm -qf $(command -v <cmd>)` (e.g. ocr-region needs grim, tesseract,
wl-clipboard, libnotify).

## 4. Add an on-demand tool (just recipe)
For tools that should be *available* rather than *installed* (the starship pattern):
add a recipe to `system_files/etc/skel/.justfile` (baked to `~/.justfile`; `just` is
installed in build.sh and discovers it when run from your home dir). Recipe pattern:
1. install — prefer brew if present, else download the official release to `~/.local/bin`
2. idempotently append shell init lines to `~/.bashrc` (`grep -q ... || echo ... >>`)
3. make sure `~/.local/bin` is on PATH in `.bashrc` (same idempotent grep)

On the target: `just starship` → open a new shell. Full recipe in PLAN.md §5.

## 5. Add a flatpak app (build-time install)
Flatpak apps can be preinstalled at build time (the uBlue/bazzite pattern). The image's
`/var` — including `/var/lib/flatpak` — is copied into the installed system's `/var`
subvolume at install time, so build-time installs survive:
```bash
# in build_files/build.sh
flatpak remote-list --system | grep -q flathub || \
  flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/
flatpak install -y --system flathub com.example.App
```
- **Verified:** `silverblue-main:44` ships flatpak but **no** `/var/lib/flatpak` —
  the flathub remote is not preconfigured, so the `remote-add` above is actually
  required (the grep guard keeps it idempotent).
- This image bakes **Bazaar** (`io.github.kolunmi.Bazaar`), a Flatpak app store, so the
  target can also add apps interactively from the app grid.
- Apps the user installs after install land in the same `/var/lib/flatpak` and persist
  across rebases (it's outside the immutable layer).
- The laptop has 11 flatpak apps (~12 G) — add more `flatpak install` lines for any
  subset you want baked (see PLAN.md §10).

## 6. Bake a user-level tool (archive + first-boot service)
Tools that live under `/home` (Homebrew) can't be baked *directly* — but you can bake
the **archive + a first-boot service** that materializes it. This is exactly what
`ghcr.io/ublue-os/brew` does (Bluefin's pattern), and this build uses it for Homebrew:
1. `FROM ghcr.io/ublue-os/brew:latest AS brew` + `COPY --from=brew /system_files /system_files`
   in the ctx stage (merges into the build.sh copy — no build.sh changes needed)
2. The image carries `/usr/share/homebrew.tar.zst` + `brew-setup.service` (oneshot,
   `ConditionPathExists`-guarded so it runs once and never clobbers a live install) +
   `profile.d/brew.sh` shell integration + update/upgrade timers
3. First boot: the service extracts to `/home/linuxbrew/.linuxbrew`, chowns to uid 1000

For your own tool: `tar --zst -cf system_files/usr/share/yourtool.tar.zst yourtree`,
then write a similar oneshot unit under `system_files/usr/lib/systemd/system/` plus a
`system-preset` file to enable it.

## 7. Change the base image
`Containerfile`, first FROM line:
- GNOME: `ghcr.io/ublue-os/silverblue-main:44` (current)
- KDE: `ghcr.io/ublue-os/kinoite-main:44`
- gaming: `ghcr.io/ublue-os/bazzite:stable`

`just build` pulls newer automatically (`--pull=newer`).

## 8. Remove something
- package → delete its dnf line from build.sh
- flatpak app → delete its `flatpak install` line from build.sh
- dotfile/script → delete the file under `system_files/`
- on-demand tool → delete the recipe from `.justfile`

Then rebuild + re-ISO.

## 9. The rebuild loop
```bash
just build          # container image  -> localhost/umbrielblue:<tag>
just build-iso      # ISO              -> output/bootiso/install.iso
just run-vm-iso     # boot it in KVM (web console) — verify BEFORE burning
```
- First build ~30–60 min (base image pull); rebuilds reuse the podman cache.
- Nightly packages (umbriel) drift between builds — VM-test every ISO before burning.
- On the installed target, updates = rebuild + rebase (PLAN.md §7).

## 10. Where things live after install
- `~/.config/...` — dotfiles (from /etc/skel)
- `~/.local/bin/...` — user scripts (from /etc/skel)
- `~/.local/state/noctalia/...` — Noctalia plugins/state (from /etc/skel)
- `~/.justfile` — on-demand recipes (`just <recipe>` from home)
- flatpak apps — `/var/lib/flatpak` (from the image's `/var`; Bazaar preinstalled)
- Homebrew — `/home/linuxbrew/.linuxbrew` (materialized at first boot from the baked
  `/usr/share/homebrew.tar.zst` by `brew-setup.service`)
- system packages — immutable; change them by editing the build and rebasing

## Gotchas
- build.sh copies `system_files` **first** — build-time steps can rely on dotfiles
  being in place (the LazyVim preinstall depends on this).
- Don't bake machine-specific state (window sizes, display names like `eDP-1`) — apps
  reconcile at runtime, but keep an eye on it when adding new state files.
- Keep `lazy-lock.json` inside the nvim config dir so plugin pins survive rebuilds.
- **Deployed content under `/home` can't be baked** (bootc creates the `/home`
  subvolume fresh at install, hiding image `/home` content) — the official pattern is
  **archive + first-boot service** (§6, the `ghcr.io/ublue-os/brew` image used by
  Bluefin). Fall back to a just-recipe installer for tools without an image.
- After any change: `just build && just build-iso && just run-vm-iso` — the VM boot is
  your acceptance test (checklist in PLAN.md §9).
