# Verdant Linux — Creator's Guide

> Maintainer's handbook: how to build, release, update, and operate Verdant Linux
> as a public project. This is for **you** (the creator), not for end users.
>
> Companions: `README.md` (what this is), `PLAN.md` (why it's built this way),
> `TUTORIAL.md` (add/change/remove recipes). This guide covers the **release
> pipeline, update cadence, administration, and public-project operations**.
>
> Current state (2026-10-25): local builds only. No `.github/workflows/` yet —
> the repo is not yet push-ready. See §2.4 for the setup checklist.

---

## 1. How Verdant Linux works

### The bootc model in one paragraph

Verdant Linux is a **bootc image**: the installed system is a deployment of one
commit of a container image. `/usr` is immutable and comes from the container;
`/etc`, `/var`, and `/home` are mutable subvolumes that **survive updates**.
"Updating" the system means pulling a newer commit of the image and *rebasing*
onto it — there is no `dnf upgrade` for system packages.

### Two artifacts, two purposes

| Artifact | Made by | Used for |
|---|---|---|
| **Container image** `ghcr.io/mortalglitch/verdant-linux:<tag>` | `build.yml` CI (or local `just build`) | **Updates** — machines pull + rebase |
| **ISO** `output/bootiso/install.iso` | `build-disk.yml` CI (or local `just build-iso`) | **Fresh installs** only |

Updates never touch the ISO. The ISO only matters when someone installs on a new
machine.

### The four inputs that define the image

1. **`Containerfile`** — the `FROM` line (currently `ghcr.io/ublue-os/silverblue-main:44`).
   This is what makes the image *track* uBlue: a moving tag, so every rebuild
   picks up whatever uBlue shipped upstream.
2. **`build_files/build.sh`** — runs at build time: copies `system_files/` into
   `/`, installs dnf packages (ghostty, btop, nvim, umbriel-nightly, noctalia,
   greetd…), cuts GDM→greetd, preinstalls LazyVim, installs flatpaks.
3. **`system_files/`** — everything baked into the image verbatim:
   - `etc/skel/...` → copied into a user's home **at account creation** (dotfiles,
     nvim/LazyVim, ocr-region, `.justfile`, wallpapers, Noctalia state)
   - `etc/yum.repos.d/terra.repo` + GPG key → the Terra repo (Umbriel/Noctalia)
   - `etc/accountsservice/user-templates/` → default-session mechanism
   - `etc/distrobox/distrobox.ini` → declarative pet containers
4. **`disk_config/iso.toml`** — the installer profile (interactive: user picks
   disk + creates account during install; no `clearpart`).

### Where things land after install (and survive updates)

- `~/.config/...`, `~/.local/...` — from skel, **at install time only**
- `/var/lib/flatpak` — flatpaks baked into the image *and* installed by the user
- `/home/linuxbrew/.linuxbrew` — Homebrew, materialized by `brew-setup.service`
- `/etc` — user edits survive; image changes to `/etc` overwrite on rebase

**The key gotcha:** skel content reaches only *new* installs and *new* accounts.
An existing user on an updated machine never receives new skel files — no new
dotfiles, no new wallpapers. Plan content distribution accordingly (§4.4).

---

## 2. The release pipeline (GitHub CI)

### 2.1 GitHub Actions in 30 seconds

A file in `.github/workflows/*.yml` is a recipe that runs **on GitHub's
servers**. Each run: a trigger fires → GitHub spins up a throwaway Ubuntu VM
("runner") → checks out your repo at that commit → runs the steps in order →
destroys the VM. Nothing persists except what the workflow publishes (here: the
image on GHCR, the ISO as an artifact).

Two mechanisms you'll meet:

- **`secrets.XXX`** — encrypted values stored in Settings → Secrets and
  variables → Actions. Injected into the run as env vars, never shown in logs.
  This is how a private key lives "in CI" without ever being in git.
- **`GITHUB_TOKEN`** — a short-lived token GitHub hands each run. With
  `permissions: packages: write`, it may push images to *your* GHCR. No password.

### 2.2 `build.yml` — the container build

Triggers (template default):

- `push` to `main` (ignores README-only changes)
- `pull_request` to `main` — **build-test only**; the `if:` guards on the push
  and sign steps mean PRs never publish or sign anything under your name
- `schedule` — cron `05 10 * * *` = **daily at 10:05 UTC** (this is the "nightly build")
- `workflow_dispatch` — manual button on the Actions tab

Steps, in order:

1. Checkout → install `just` → `just check` (syntax gate)
2. `just build` — podman build (pulls base, runs your `build.sh`)
3. `just ostree-rechunk` — re-slices packages so delta updates are smaller
4. `just generate-build-tags` + `just tag-images` — tag the image
5. Login to GHCR with `GITHUB_TOKEN` → `podman push` every tag, save the digest
6. Install cosign → **sign** the pushed image by digest (see §2.4)

**Tags.** Every build pushes the moving tag `44` (your `DEFAULT_TAG`) *and*,
when the tree is clean, immutable tags: `44-<sha>`, `44-<date>-<sha>`,
`<date>-<sha>`. The immutable tags matter: they let you pin a bug report to the
exact build, and roll out a "known good" image.

### 2.3 `build-disk.yml` — the ISO build

Runs bootc-image-builder against the GHCR image → ISO/qcow2/raw, uploaded as
workflow artifacts (optionally to S3). When wiring it up, set its
`IMAGE_REGISTRY` / `IMAGE_NAME` / `DEFAULT_TAG` env vars to
`ghcr.io/mortalglitch` / `verdant-linux` / `44`. Your local `disk_config/iso.toml`
is profile-only (no embedded ref) and works as-is.

### 2.4 Cosign + setup checklist (what's missing right now)

**Cosign** signs the image with a keypair: `cosign.pub` is committed to the repo
(anyone can verify), `cosign.key` is stored as the repo secret `SIGNING_SECRET`
(only the runner sees it). The signature is pushed to the registry alongside the
image and pins the exact bytes (signed by **digest**, not tag). Verification:

```sh
cosign verify --key cosign.pub ghcr.io/mortalglitch/verdant-linux@<digest>
```

The template's signing step uses `--new-bundle-format=false` deliberately — it
keeps the signature readable by the bootc/rpm-ostree verification stack.
Signing is technically optional (template comment: "only needed if you plan on
distributing to others") — but for a public image it's cheap tamper-evidence.
Keep it.

**Setup checklist** (do in this order, while the repo is still private):

1. Copy `.github/workflows/build.yml` + `build-disk.yml` from
   [ublue-os/image-template](https://github.com/ublue-os/image-template) into
   the repo (the local clone currently has no `.github/`).
2. Generate the keypair and wire the secret:
   ```sh
   cosign generate-key-pair            # writes cosign.pub + cosign.key (no password)
   git add cosign.pub && git commit -m "Add cosign public key"
   gh secret set SIGNING_SECRET < cosign.key
   rm cosign.key
   ```
3. Point `build-disk.yml` at `ghcr.io/mortalglitch/verdant-linux:44`.
4. `git push` → repo **Actions** tab → enable workflows (new repos start with
   them disabled).
5. Watch the first run: green build → image on GHCR → signature present →
   ISO artifact downloadable.
6. Test the *update path* end-to-end before going public: on a VM,
   `bootc switch --image ghcr.io/mortalglitch/verdant-linux:44`, then push a
   trivial commit and `bootc upgrade` on the VM. If that loop works, the public
   flow works.
7. Only then: flip the repo public (§6).

---

## 3. Controlling the update cadence

"Why do my machines get daily updates?" — because two things compound:

1. **`umbriel-nightly`** (Terra repo) means the image content can differ between
   builds even when *you* change nothing.
2. The template's cron rebuilds **daily at 10:05 UTC** and refreshes the moving
   tag `:44`. A machine tracking `:44` that runs `bootc upgrade` then picks up
   yesterday's build.

There are **two dials**. Keep them separate in your head:

### Dial 1 — the machine (when a machine pulls)

Updates are **manual** in this setup. A machine does nothing on its own; it
changes only when someone runs:

```sh
bootc upgrade        # pull newer commit of the tracked image, stage deployment
systemctl reboot     # activate
rpm-ostree status    # see current + staged deployments
bootc switch --rollback   # undo a bad update
```

So even with a daily CI build, machines update only as often as you (or your
users) run `bootc upgrade`. If you ever want auto-*staging* (like stock uBlue's
`uupd` timer), that's a systemd timer running `bootc upgrade` — but manual is
the sane default for a small project: users update when they choose.

### Dial 2 — CI (how often the image on GHCR changes)

Three settings, pick one:

**A. Push-only (recommended to start).** Delete the `schedule:` block from
`build.yml`. The image changes *only when you push a commit*. Want the latest
base/nightly without local changes? Push a no-op commit (`git commit --allow-empty
-m "rebuild"`). You are in full control of when `:44` moves.

**B. Slower cron.** Keep the schedule, change the frequency:

```yaml
schedule:
  - cron: '05 10 * * 0'    # weekly, Sunday 10:05 UTC
  # '05 10 1,15 * *'       # twice monthly (1st + 15th) — cron can't do biweekly
```

**C. Channel split (when you have a community).** Two channels, two tags:

- `:44` (stable) — built **on push only**; you promote deliberately
- `:nightly` — built on the daily cron; whatever the night produced

Implementation: a second workflow (or an `inputs:` option on `workflow_dispatch`)
that runs the same build with `DEFAULT_TAG=nightly` on the schedule, while
push-builds keep tagging `44`. Machines pick a channel once:

```sh
bootc switch --image ghcr.io/mortalglitch/verdant-linux:44      # stable
bootc switch --image ghcr.io/mortalglitch/verdant-linux:nightly # bleeding edge
```

This is the standard answer to "I like that users get fresh builds, but not
*every* day": the nightly channel absorbs the churn, and you promote to stable
when a nightly has been fine for a few days.

**Recommendation:** A now (it matches "I have more changes coming anyway"), C
once real users exist. B is the lazy middle.

---

## 4. Administration tutorials

Every change follows the same loop: **edit → `just build` → verify the image →
`just build-iso` → VM-test → (push → CI) → users `bootc upgrade`**. The local
loop is §4.7; the rest is "what to edit."

### 4.1 Add a system package (dnf)

1. **Check it exists before baking** — zero results means "on-demand just
   recipe" (§4.3), not a dnf install:
   ```sh
   podman run --rm --entrypoint sh ghcr.io/ublue-os/silverblue-main:44 \
     -c 'dnf5 -q repoquery <pkg>'
   ```
2. Add it to the `dnf5 -y install` list in `build_files/build.sh` (group
   related packages; the file is organized by concern).
3. **COPR packages** — uBlue convention is enable → install → disable:
   ```sh
   dnf5 -y copr enable <owner>/<repo>
   dnf5 -y install <pkg>
   dnf5 -y copr disable <owner>/<repo>
   ```
   (COPRs left enabled in the image are discouraged by uBlue.)
4. **Third-party repo** — the Terra pattern is your template: repo file + GPG
   key under `system_files/etc/yum.repos.d/` + `system_files/etc/pki/rpm-gpg/`.
   Note: `terra.repo` carries `gpgcheck=0` *deliberately* — bootc-image-builder's
   manifest step can't read `file://` keys (and dnf5 ignores
   `/etc/dnf/repos.override.d`). Packages are still GPG-verified during the
   container build. Document this in the public README FAQ.
5. **Pitfall:** Hyprland-COPR deps break the build (`hyprpicker` → "No match for
   argument"). Umbriel-side screen tools: use `grim -s` (built-in selection),
   which is what `ocr-region` already does.
6. Verify the built image actually contains it:
   ```sh
   podman run --rm --entrypoint sh localhost/verdant-linux:44 -c 'rpm -q <pkg>'
   ```

### 4.2 Add a flatpak app

The flathub remote is already added in `build.sh`. Add a line:

```sh
flatpak install -y --system flathub <app.id>
```

Users can also install interactively via **Bazaar** (baked). Anything a user
installs on their machine lands in the same `/var/lib/flatpak` and **survives
rebases** — so flatpaks are the lowest-friction "app" channel: bake the common
ones, let the rest be user-installed.

### 4.3 Add a dotfile / script / on-demand tool

- **Per-user, at install:** `system_files/etc/skel/<path>` → `~user/<path>` when
  the account is created. (Remember the gotcha from §1: never reaches existing users.)
- **System-wide:** `system_files/<path>` → `/<path>`. For files users should be
  able to edit later, prefer `/usr/etc` (OSTree template, preserved across updates).
- **On-demand tools:** a recipe in `system_files/etc/skel/.justfile` (the
  `starship` and `brew` recipes are the pattern). Requirements: **idempotent**
  (`command -v x || install`, `grep -q marker ~/.bashrc || echo …`), and
  self-contained (the target may not have what your laptop has).

### 4.4 Add wallpapers

Current wiring (verified 2026-10-25):

- Files: `system_files/etc/skel/Pictures/Wallpapers/star-trails-light.png`
  (the default) + `star-trails-dark.png` (alternative, ~0.7 MB each —
  users can switch via Noctalia's wallpaper settings; the old 3 MB
  `default.png` was removed 2026-10-25)
- Noctalia lockscreen: `settings.toml` → `[wallpaper] directory =
  "~/Pictures/Wallpapers"` + `[wallpaper.default] path =
  "…/star-trails-light.png"`

**Add one (new installs):**

1. Drop the image at `system_files/etc/skel/Pictures/Wallpapers/<name>.png`.
   Keep it lean: ~3 MB per 4K PNG is the current norm; JPEG is fine for
   photographic art and much smaller.
2. To make it the lockscreen default, update `[wallpaper.default] path` in
   `system_files/etc/skel/.local/state/noctalia/settings.toml`.
3. Rebuild + re-ISO.

**The skel gotcha bites here:** existing users on updated machines never
receive new wallpapers. If wallpapers should reach *all* machines, add an
on-demand recipe instead (or in addition):

```just
# fetch a wallpaper into ~/Pictures/Wallpapers (idempotent, works on old installs)
wallpaper name:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/Pictures/Wallpapers"
    curl -fsSL -o "${HOME}/Pictures/Wallpapers/{{name}}.png" \
      "https://raw.githubusercontent.com/mortalglitch/verdant-linux/main/system_files/etc/skel/Pictures/Wallpapers/{{name}}.png"
    echo "installed {{name}} — pick it in Noctalia's wallpaper settings"
```

`just wallpaper forest` on any machine, new or old, no rebuild required.

### 4.5 Change the base image / move to Fedora 45

1. `Containerfile` `FROM` → `ghcr.io/ublue-os/silverblue-main:45`
   (verify the tag exists on GHCR first).
2. `image-template.env` → `DEFAULT_TAG="45"`.
3. `terra.repo` uses `$releasever` — it adapts automatically, **but verify a
   Terra 45 build of `umbriel-nightly`/`noctalia`/`noctalia-greeter` exists** or
   the build will fail at the dnf step.
4. Re-test the greeter stack (greetd + Noctalia + accounts-service templates) —
   version bumps are where the default-session behavior regresses.
5. Full VM test (§4.7) + fresh ISO. This is a **major release**, not a patch:
   tag it in git and the changelog.

### 4.6 Remove something

- package → delete its dnf line from `build.sh`
- flatpak → delete its `flatpak install` line
- dotfile/script → delete the file under `system_files/`
- on-demand tool → delete the recipe from `.justfile`

Then rebuild + re-ISO. (Removing from the image does not remove it from
already-installed machines' mutable layers — only `/usr`-content gets replaced
on rebase; a user-installed flatpak stays.)

### 4.7 The local rebuild loop + verification

```sh
just build          # container image -> localhost/verdant-linux:44
just build-iso      # installable ISO -> output/bootiso/install.iso
just run-vm-iso     # boot it (web console) — VERIFY BEFORE BURNING/SIPPING
```

- **`build-iso` does NOT rebuild the image** — it bakes whatever
  `localhost/verdant-linux:44` currently is. A build-affecting commit followed
  by `build-iso` gives you a stale ISO. Use `just rebuild-iso` (build + iso), or
  verify the tagged image first (`podman run … rpm -q …`).
- VM checklist before shipping: session starts (greeter → Umbriel), apps open
  with expected themes, `ocr-region` works, `just <recipe>` works, new shell
  shows expected prompt, Homebrew ready (`brew --version`), flatpaks present.
- **Nightly drift:** `umbriel-nightly` moves between builds — VM-test *every*
  ISO you ship, not just the first.
- Known build-machine pitfalls (all fixed in this repo, but they'll bite a
  re-clone): paths with spaces break the template Justfile (quoting fix
  committed here); `build-iso` stages ~12 GB in /tmp (self-heal at the top of
  `_rootful_load_image`); `build-iso` needs root — you run it yourself in a
  terminal, it takes 30–60 min.
- Log discipline: `just … 2>&1 | tee build.log` reports *tee's* exit code —
  use `set -o pipefail` and check for `output/bootiso/install.iso`'s existence,
  not the exit code.

---

## 5. Bug reports & community operations

### 5.1 Channel split

- **Issues** = defects only (crashes, wrong behavior, build failures).
- **GitHub Discussions** (enable in repo Settings → Features) = how-tos,
  "does X work?", support. This keeps the issue tracker signal-dense.
  Categories: *Support*, *Show & Tell*.
- Pin two issues: **Welcome / FAQ** (what it is, install, update, support
  boundary) and **Known issues** (live list, updated per release).

### 5.2 Issue templates (paste-ready)

`.github/ISSUE_TEMPLATE/bug-report.yml`:

```yaml
name: Bug report
description: Something is broken — crash, wrong behavior, failed update
labels: [bug]
body:
  - type: textarea
    id: what
    attributes:
      label: What happened?
      description: What you saw, and what you expected instead.
    validations:
      required: true
  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
    validations:
      required: true
  - type: textarea
    id: system
    attributes:
      label: System info
      description: Paste the output of the commands in the note below.
      render: shell
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Relevant logs
      render: shell
  - type: notes
    attributes:
      label: How to gather system info
      value: |
        ```sh
        rpm-ostree status                        # which build (digest) you're on
        journalctl -b -p err --no-pager | tail -n 50
        journalctl --user -b -u umbriel.service --no-pager | tail -n 50   # Umbriel issues
        journalctl -b -u greetd --no-pager | tail -n 50                   # login issues
        ```
```

`.github/ISSUE_TEMPLATE/config.yml`:

```yaml
blank_issues_enabled: true
contact_links:
  - name: Question / support
    url: https://github.com/mortalglitch/verdant-linux/discussions
    about: How-to and support questions belong in Discussions, not Issues.
```

### 5.3 Labels

`bug` (auto from template), `enhancement`, `question`, `duplicate`, `wontfix`,
`needs-repro`, `upstream` (it's Umbriel/Noctalia's bug, not the image's),
`good-first-issue`, `P1` (blocks install/login/update), `P2` (annoying, has
workaround).

### 5.4 The triage ritual (10 minutes, once a day)

1. **Check the build first.** `rpm-ostree status` in the report shows the
   digest. If it's older than your last stable push, reply: "please `bootc
   upgrade` and retest" — a large share of "bugs" are fixed builds.
2. **Reproduce** on a VM at that exact digest (immutable `44-<sha>` tags exist
   for this). Can't reproduce → `needs-repro`, ask for the missing logs.
3. **Classify:** image bug (fix in `build.sh`/`system_files` → PR → merge),
   upstream bug (`upstream` label + report to Umbriel/Noctalia repo, track it),
   won't-fix (explain *why* in the close comment — "we use `grim -s` instead of
   hyprpicker" is a legitimate wontfix).
4. **Decide the rollout:** a P1 on stable gets a patched rebuild pushed to `:44`
   promptly; P2 rides the next cycle. Announce the fix in the issue *and* the
   changelog.
5. **Close with a comment.** Never silent-close. "Fixed in `<sha>`, will be in
   the next `:44` build" is a complete close.

### 5.5 Maintainer boundaries (say this once, up front)

Pin it in the Welcome issue and the README:

- Solo maintainer, personal project — **no SLA, no guaranteed response time**.
- Priority: bugs on common hardware > rare setups; P1s (can't install/login)
  jump the queue.
- Umbriel/Noctalia are upstream nightlies — some "Verdant bugs" are upstream;
  check the Umbriel repo before filing.
- Stale issues close after ~2 weeks without a reply (state this in
  `config.yml`'s notes or the FAQ).

### 5.6 Security reports

Before going public: Settings → General → Features → **Enable private
vulnerability reporting**, and add a `SECURITY.md` ("report via GitHub's
vulnerability form; do not open a public issue"). Realistically the attack
surface is small (your CI + the image), but the form being open is free, and
"reporting a vuln opens a public issue" is the one thing that embarrasses a
new public project.

---

## 6. Going public — checklist

Do this in order, with the repo **private** until step 5 passes.

**1. Re-run the secret scan** (last run 2026-10-25: clean):

```sh
grep -rniE 'api[_-]?key|secret|token|passwd|password|BEGIN (RSA|OPENSSH|EC) PRIVATE|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}' \
  system_files build_files Containerfile
```

**2. Personalization audit.** The image currently carries your fingerprint:

- `system_files/etc/skel/.config/umbriel/config.toml` → `[output."eDP-1"]
  scale = 1.2` is **machine-specific** (your laptop's panel). Public users with
  other displays get a mismatched scale. Delete or generalize before public.
  The CJK workspace renames (一…十) are a personal preference — keep or drop,
  your call, but know they ship to everyone.
- Everything else (btop/ghostty/nvim configs, Noctalia templates, themes) is
  opinionated but not personal — fine to ship, and it *is* the product.
- `IMAGE_LOGO_URL` points at your GitHub avatar — intended.

**3. Docs for strangers.** `README.md` is currently written for you ("Personal
bootc image", PLAN/TUTORIAL links). Rewrite: what it is, features, install
(ISO link), updating (`bootc upgrade`), the Terra `gpgcheck=0` explanation,
support boundary (§5.5), license note. Move `PLAN.md` / `TUTORIAL.md` / this
guide under `docs/` if you want the root to read like a product — or leave
them; they're honest about how it's built.

**4. Repo hardening (Settings):**

- Branch protection on `main`: require PR + passing build check, no
  force-push, no self-merge (or at least: no force-push + required status check).
- Enable **Discussions**; create Support + Show & Tell categories.
- Enable **private vulnerability reporting** + `SECURITY.md` (§5.6).
- Add the issue templates (§5.2).
- Pin: Welcome/FAQ + Known issues.

**5. End-to-end test (private repo):** push → CI green → image + signature on
GHCR → ISO artifact → VM: install from ISO, `bootc switch` to the GHCR ref,
push a commit, `bootc upgrade`, reboot, verify. This is the exact loop your
users will live in.

**6. Versioning + flip:**

- `git tag v1.0.0` on the public-ready commit; start a `CHANGELOG.md`
  (per release: base version, notable changes, known issues).
- GHCR: public repo → public package (default) — anyone can pull, no auth.
  (If you ever make the repo private, pulls require a GHCR token on every
  machine — don't.)
- Flip the repo public. Announce.

**7. Naming/legal (one paragraph, so you can sleep):**

- Say "based on uBlue Silverblue / Fedora" — descriptive use is fine. Do not
  imply uBlue endorsement or use the uBlue name in your project name/descriptor
  as if it were theirs.
- Apache-2.0 LICENSE (from the template) covers your build files; your baked
  configs are your work, same license. Upstream packages (Fedora, RPMfusion,
  Terra) are redistributed unmodified — that's what package repos are for.
- Flatpak app IDs and the Noctalia template catalog are upstream content —
  fine to ship, same as any app-store listing.

---

## 7. Cheat sheet

```sh
# ── build (local) ────────────────────────────────────────────────
just build            # image -> localhost/verdant-linux:44
just rebuild-iso      # build + ISO (never build-iso after a change alone)
just run-vm-iso       # acceptance test
podman run --rm --entrypoint sh localhost/verdant-linux:44 -c 'rpm -q <pkg>'

# ── release (GitHub) ─────────────────────────────────────────────
git push              # CI builds + pushes :44 + immutable sha tags, signs
# Actions tab: runs, logs, ISO artifacts

# ── target machine ───────────────────────────────────────────────
rpm-ostree status                     # current build (digest) + deployments
bootc upgrade                         # pull + stage newer build
systemctl reboot                      # activate
bootc switch --image ghcr.io/mortalglitch/verdant-linux:44   # track a channel
bootc switch --rollback               # undo
cosign verify --key cosign.pub ghcr.io/mortalglitch/verdant-linux@<digest>

# ── bug triage asks ──────────────────────────────────────────────
rpm-ostree status
journalctl -b -p err --no-pager | tail -n 50
journalctl --user -b -u umbriel.service --no-pager | tail -n 50
journalctl -b -u greetd --no-pager | tail -n 50
```

### Glossary

- **Rebase** — deploy a new commit of the tracked image, keeping `/etc`,
  `/var`, `/home`. The only "update" in bootc.
- **Digest** (`sha256:…`) — content hash of an image; immutable. Tags move,
  digests don't. Signatures and bug reports pin digests.
- **Deployment** — one installed commit; `rpm-ostree status` lists them; the
  previous one is your rollback.
- **GHCR** — GitHub Container Registry; where CI publishes the image.
- **Skel** (`/etc/skel`) — the template home directory, copied into a new
  account's `~` at creation. Install-time only.
- **Rechunk** — re-slicing OSTree content so subsequent deltas are smaller.
- **Moving vs immutable tag** — `:44` (always latest) vs `:44-<sha>` (one
  specific build).
