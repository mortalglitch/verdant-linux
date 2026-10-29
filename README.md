# verdant-linux

TEMP README. More details and links to come. 

bootc image: **Umbriel + Noctalia** on `silverblue-main:44`, with
Neovim + LazyVim (preinstalled), ghostty, btop, starship (on-demand), ocr-region,
Homebrew (baked via the Bluefin pattern), and Flatpak + Bazaar.

- **Justfile** — build recipes (from [ublue-os/image-template](https://github.com/ublue-os/image-template))
- **Containerfile / build_files/** — image definition and build-time setup
- **system_files/** — files baked into the image (dotfiles, configs, recovery recipes)

## Quick start

```bash
just build        # container image -> localhost/verdant-linux:44
just build-iso    # installable ISO -> output/bootiso/install.iso
just run-vm-iso   # try it in a VM first (noVNC at http://localhost:8006)
```

First build takes ~30–60 min (base image is pulled locally; LazyVim sync +
Bazaar download + ISO build are the slow parts).

## Updates

Container images are pushed to `ghcr.io/mortalglitch/verdant-linux` on every
push to `main` and cosign-signed (public key: `cosign.pub`). Update a running
system with `bootc upgrade` after selecting this image as your container.
