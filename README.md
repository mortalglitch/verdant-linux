# verdant-linux

Personal bootc image: **Umbriel + Noctalia** on `silverblue-main:44`, with
Neovim + LazyVim (preinstalled), ghostty, btop, starship (on-demand), ocr-region,
Homebrew (baked via the Bluefin pattern), and Flatpak + Bazaar.

- **PLAN.md** — full build plan: inventory, Containerfile/build.sh walkthrough, first-boot notes
- **TUTORIAL.md** — how to add / change / remove anything and rebuild
- **Justfile** — build recipes (from [ublue-os/image-template](https://github.com/ublue-os/image-template))

## Quick start

```bash
just build        # container image -> localhost/verdant-linux:44
just build-iso    # installable ISO -> output/bootiso/install.iso
just run-vm-iso   # try it in a VM first (noVNC at http://localhost:8006)
```

First build takes ~30–60 min (base image is pulled locally; LazyVim sync +
Bazaar download + ISO build are the slow parts).
