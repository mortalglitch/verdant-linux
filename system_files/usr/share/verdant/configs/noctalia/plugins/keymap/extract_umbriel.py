#!/usr/bin/env python3
"""extract_umbriel.py — bundled with the keymap plugin.

Extracts Umbriel keybindings from ~/.config/umbriel/config.toml (following
[include] files) and emits a JSON array of {chord, description, category} on
stdout — the same shape as extract_binds.lua for Hyprland.

Usage: python3 extract_umbriel.py [path-to-config.toml]
"""

import json
import os
import re
import sys
import tomllib

# Human names for `spawn:noctalia msg <sub>` — kept in sync with extract_binds.lua.
NOCTALIA_NAMES = {
    "panel-toggle launcher": "Open app launcher",
    "panel-toggle session": "Open session menu",
    "panel-toggle clipboard": "Open clipboard history",
    "panel-toggle wallpaper": "Open wallpaper panel",
    "panel-toggle control-center": "Open control center",
    "settings toggle": "Open settings",
    "screenshot-fullscreen pick": "Screenshot (pick monitor)",
    "screenshot-fullscreen": "Screenshot (all)",
    "screenshot-region": "Screenshot region",
    "volume-up": "Volume up",
    "volume-down": "Volume down",
    "volume-mute": "Mute audio",
    "mic-mute": "Mute microphone",
    "media toggle": "Media play / pause",
    "media next": "Media next track",
    "media previous": "Media previous track",
    "brightness-up": "Brightness up",
    "brightness-down": "Brightness down",
}

# Umbriel action verbs with no parameter.
NAMED_ACTIONS = {
    "window-close": "Close window",
    "window-toggle-floating": "Toggle floating",
    "window-toggle-maximize": "Toggle maximize",
    "window-toggle-fullscreen": "Toggle fullscreen",
    "window-focus-left": "Focus window left",
    "window-focus-right": "Focus window right",
    "window-focus-up": "Focus window up",
    "window-focus-down": "Focus window down",
    "workspace-next": "Next workspace",
    "workspace-previous": "Previous workspace",
    "workspace-focus-last": "Last workspace",
    "scratchpad-toggle": "Toggle scratchpad",
    "window-move-to-scratchpad": "Move window to scratchpad",
    "layout-toggle-split": "Toggle dwindle split",
}


def describe_exec(cmd):
    if "ocr-region" in cmd:
        return "OCR region (copy text)"
    m = re.search(r"noctalia\s+msg\s+(.+)$", cmd)
    if m:
        sub = m.group(1).strip()
        return NOCTALIA_NAMES.get(sub, "Noctalia: " + sub)
    m = re.search(r"uwsm\s+app\s+--\s*(.+)$", cmd)
    if m:
        return "Open " + m.group(1).strip()
    return "Run " + cmd


def describe(action):
    # Table form: { action = "...", cooldown_ms = 150, repeat = true }
    if isinstance(action, dict):
        action = action.get("action", "")
    a = str(action).strip()
    if not a:
        return "Bound"
    if a.startswith("spawn:"):
        return describe_exec(a[len("spawn:"):].strip())
    base, _, param = a.partition(":")
    if base in NAMED_ACTIONS:
        return NAMED_ACTIONS[base]
    if base == "workspace-switch":
        return "Switch to workspace " + param
    if base == "window-move-to-workspace":
        return "Move window to workspace " + param
    if base == "window-move-to-workspace-silent":
        return "Move window to workspace " + param + " (stay put)"
    if base in ("window-modify-width-left", "window-modify-width-right",
                "window-modify-height-up", "window-modify-height-down"):
        return "Resize window " + base.rsplit("-", 1)[1]
    return a


def categorize(action):
    if isinstance(action, dict):
        action = action.get("action", "")
    return "Noctalia" if "noctalia" in str(action) else "Umbriel"


def find_config():
    """First hit wins, mirroring Umbriel's own config lookup order:
    $XDG_CONFIG_HOME/umbriel/config.toml, then each directory in
    $XDG_CONFIG_DIRS (default /etc/xdg), then ~/.config as a last resort.

    The system layer matters: on fresh installs the only config is the
    /etc/xdg/umbriel/config.toml baked into the image (see the build's
    `customize-umbriel` recipe), and XDG_CONFIG_HOME alone never sees it."""
    home = os.path.expanduser("~")
    xcfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    dirs = [xcfg]
    for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(os.pathsep):
        if d and d not in dirs:
            dirs.append(d)
    fallback = os.path.join(home, ".config")
    if fallback not in dirs:
        dirs.append(fallback)
    for d in dirs:
        cand = os.path.join(d, "umbriel", "config.toml")
        if os.path.isfile(cand):
            return cand
    return None


def collect_keybinds(path, seen=None, out=None):
    """Merge [keybinds] from path and every [include] file it references."""
    if seen is None:
        seen = set()
    if out is None:
        out = {}
    real = os.path.realpath(path)
    if real in seen:
        return out
    seen.add(real)
    try:
        with open(real, "rb") as f:
            data = tomllib.load(f)
    except Exception as e:
        print("ERR parsing {}: {}".format(real, e), file=sys.stderr)
        return out
    base_dir = os.path.dirname(real)
    inc = data.get("include")
    files = None
    if isinstance(inc, dict):
        files = inc.get("files")
    elif isinstance(inc, list):
        files = inc
    for name in files or []:
        fp = name if os.path.isabs(name) else os.path.join(base_dir, name)
        if os.path.isfile(fp):
            collect_keybinds(fp, seen, out)
        else:
            print("WARN include not found: {}".format(fp), file=sys.stderr)
    for chord, action in data.get("keybinds", {}).items():
        out[chord] = action  # last definition wins
    return out


def main():
    cfg = sys.argv[1] if len(sys.argv) > 1 else find_config()
    if not cfg or not os.path.isfile(cfg):
        print("ERR: umbriel config not found: {}".format(cfg), file=sys.stderr)
        print("[]")
        sys.exit(1)
    binds = collect_keybinds(cfg)
    out = []
    for chord, action in binds.items():
        out.append({
            "chord": " ".join(chord.split()),
            "description": describe(action),
            "category": categorize(action),
        })
    print(json.dumps(out))


if __name__ == "__main__":
    main()
