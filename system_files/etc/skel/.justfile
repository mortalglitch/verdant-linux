# On-demand tools for the target machine (run: just <recipe>)

# default: `just` with no args lists the recipes instead of auto-running the
# first one — install recipes (starship, brew) stay opt-in and gated.
[default]
help:
    just --list

# starship: install the starship prompt (brew if available, else official release
# binary). Asks for confirmation before installing.
starship:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v starship >/dev/null; then
      echo "starship already installed: $(starship --version)"
      exit 0
    fi
    read -r -p "Install starship? [y/N] " ans || ans="N"
    case "${ans:-N}" in
      y|Y|yes|YES|Yes) ;;
      *) echo "Aborted — starship was not installed."; exit 1 ;;
    esac
    if command -v brew >/dev/null; then
      brew install starship
    else
      url=$(curl -sS https://api.github.com/repos/starship/starship/releases/latest \
        | grep -o 'https://[^"]*starship-x86_64-unknown-linux-gnu\.tar\.gz' | head -1)
      curl -fsSLo /tmp/starship.tar.gz "$url"
      mkdir -p "${HOME}/.local/bin"
      tar -xzf /tmp/starship.tar.gz -C /tmp
      mv /tmp/starship-x86_64-unknown-linux-gnu/starship "${HOME}/.local/bin/"
      rm -rf /tmp/starship.tar.gz /tmp/starship-x86_64-unknown-linux-gnu
    fi
    grep -q 'starship init bash' "${HOME}/.bashrc" || echo 'eval "$(starship init bash)"' >> "${HOME}/.bashrc"
    starship --version

# brew: fallback installer (primary path is the baked archive + brew-setup.service,
# which runs automatically at first boot)
brew:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v brew >/dev/null; then
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    grep -q 'linuxbrew' "${HOME}/.bashrc" || echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${HOME}/.bashrc"
    echo "brew ready — open a new shell (or: source ~/.bashrc)"

# restore-umbriel: restore the original Umbriel config (+ Noctalia palette) from /etc/skel
# Current files are backed up as <name>.broken-<timestamp>, then the config is reloaded.
restore-umbriel:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in config.toml noctalia.toml; do
      src="/etc/skel/.config/umbriel/$f"
      dst="${HOME}/.config/umbriel/$f"
      [ -f "$src" ] || { echo "ERROR: pristine copy missing: $src" >&2; exit 1; }
      if cmp -s "$src" "$dst"; then
        echo "ok: umbriel/$f already matches the original"
        continue
      fi
      if [ -f "$dst" ]; then
        bak="${dst}.broken-$(date +%Y%m%d-%H%M%S)"
        mv "$dst" "$bak"
        echo "backed up umbriel/$f -> $(basename "$bak")"
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      echo "restored umbriel/$f"
    done
    if umbriel msg config-reload 2>/dev/null; then
      echo "umbriel: config reloaded"
    else
      echo "umbriel: reload failed — if the session is broken, log out and back in"
    fi

# restore-noctalia: restore the original Noctalia settings from /etc/skel
# Current file is backed up as settings.toml.broken-<timestamp>, then reloaded (or restarted).
restore-noctalia:
    #!/usr/bin/env bash
    set -euo pipefail
    src="/etc/skel/.local/state/noctalia/settings.toml"
    dst="${HOME}/.local/state/noctalia/settings.toml"
    [ -f "$src" ] || { echo "ERROR: pristine copy missing: $src" >&2; exit 1; }
    if cmp -s "$src" "$dst"; then
      echo "ok: noctalia settings.toml already matches the original"
      exit 0
    fi
    if [ -f "$dst" ]; then
      bak="${dst}.broken-$(date +%Y%m%d-%H%M%S)"
      mv "$dst" "$bak"
      echo "backed up noctalia settings.toml -> $(basename "$bak")"
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "restored noctalia settings.toml"
    if pgrep -x noctalia >/dev/null; then
      if noctalia msg config-reload 2>/dev/null; then
        echo "noctalia: config reloaded"
      else
        echo "noctalia: reload failed — try: pkill noctalia && noctalia -d"
      fi
    else
      echo "noctalia: not running — starting a fresh instance"
      noctalia -d
    fi

# restore-config: restore the original Umbriel + Noctalia config from /etc/skel
restore-config: restore-umbriel restore-noctalia
    echo "All done — if anything still looks off, log out and back in."

# ssh: optional SSH access — just ssh <enable|disable|status>
ssh *action:
    just -f "${HOME}/.config/verdant/ssh.just" {{ action }}
