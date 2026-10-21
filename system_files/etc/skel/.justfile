# On-demand tools for the target machine (run: just <recipe>)

# starship: brew if available, else official release binary
starship:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v starship >/dev/null; then
      echo "starship already installed: $(starship --version)"
      exit 0
    fi
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
