#!/usr/bin/env bash
set -euo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
css_chrome="$cache_dir/noctalia/zen-browser/zen-userChrome.css"
css_content="$cache_dir/noctalia/zen-browser/zen-userContent.css"

# Flatpak zen keeps its profiles in the app's sandbox home and can only see
# that home (plus xdg-download), so the rendered CSS must be mirrored into
# the sandbox cache dir and imported via a sandbox-visible path. Inside the
# sandbox the app home is bind-mounted onto $HOME itself.
flatpak_home="$HOME/.var/app/app.zen_browser.zen"
flatpak_css_dir="$flatpak_home/cache/noctalia/zen-browser"
if [ -d "$flatpak_home" ]; then
    mkdir -p "$flatpak_css_dir"
    cp -f "$css_chrome" "$flatpak_css_dir/zen-userChrome.css"
    cp -f "$css_content" "$flatpak_css_dir/zen-userContent.css"
fi

write_if_changed() {
    local target="$1" tmp="$2"
    if ! cmp -s "$target" "$tmp"; then
        cat "$tmp" >"$target"
    fi
    rm -f "$tmp"
}

zen_dirs=()
for d in "${XDG_CONFIG_HOME:-$HOME/.config}/zen" "$HOME/.zen" \
         "$flatpak_home/.zen" "$flatpak_home/config/zen"; do
    [ -d "$d" ] && zen_dirs+=("$d")
done
[ "${#zen_dirs[@]}" -eq 0 ] && exit 0

find "${zen_dirs[@]}" -mindepth 2 -maxdepth 2 -type f -name "prefs.js" -print0 |
    while IFS= read -r -d '' prefs_file; do
        profile_dir=$(dirname "$prefs_file")

        # Pick import paths the profile's zen process can actually read.
        if [[ "$profile_dir" == "$flatpak_home"/* ]]; then
            # Inside the sandbox the private app home is mounted at this same
            # absolute path, so the sandboxed zen resolves the import here.
            line_chrome="@import \"$flatpak_home/cache/noctalia/zen-browser/zen-userChrome.css\";"
            line_content="@import \"$flatpak_home/cache/noctalia/zen-browser/zen-userContent.css\";"
        else
            line_chrome="@import \"$css_chrome\";"
            line_content="@import \"$css_content\";"
        fi

        chrome_dir="$profile_dir/chrome"
        user_chrome="$chrome_dir/userChrome.css"
        user_content="$chrome_dir/userContent.css"
        user_js="$profile_dir/user.js"

        mkdir -p "$chrome_dir"
        touch "$user_chrome" "$user_content" "$user_js"

        # @import must come before any other CSS rule, so prepend it
        tmp_chrome="$(mktemp "${user_chrome}.tmp.XXXXXX")"
        printf '%s\n' "$line_chrome" >"$tmp_chrome"
        sed '/zen-browser\/zen-userChrome\.css/d' "$user_chrome" >>"$tmp_chrome"
        write_if_changed "$user_chrome" "$tmp_chrome"

        tmp_content="$(mktemp "${user_content}.tmp.XXXXXX")"
        printf '%s\n' "$line_content" >"$tmp_content"
        sed '/zen-browser\/zen-userContent\.css/d' "$user_content" >>"$tmp_content"
        write_if_changed "$user_content" "$tmp_content"

        tmp_js="$(mktemp "${user_js}.tmp.XXXXXX")"
        sed \
            -e '/toolkit\.legacyUserProfileCustomizations\.stylesheets/d' \
            -e '/devtools\.chrome\.enabled/d' \
            "$user_js" >"$tmp_js"
        [ -s "$tmp_js" ] && [ -n "$(tail -c1 "$tmp_js")" ] && echo >>"$tmp_js"
        printf '%s\n' \
            'user_pref("devtools.chrome.enabled", true);' \
            'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >>"$tmp_js"
        write_if_changed "$user_js" "$tmp_js"
    done
