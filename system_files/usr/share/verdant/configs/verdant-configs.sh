#!/usr/bin/env bash
# verdant-configs.sh — Verdant config update helper
#
# Subcommands: seed | check | upgrade | customize-umbriel | notify-check | ledger-file <path>
#
# The canonical config tree ships in the image at $CANON (updated by
# `bootc upgrade`). This helper keeps a per-user ledger in $LEDGER and
# applies updates as 3-way merges (git merge-file) so local edits survive.
#
# Design: Verdant Planning/config-update-flow-design.md
#   - explicit managed set (never directory wildcards)
#   - first run is seed-only (non-destructive; the one-time Umbriel
#     migration, which has a true merge base in archive/v1, is the exception)
#   - any operation that writes a managed file updates the ledger in the
#     same operation (ledger invariant)

set -uo pipefail

CANON="${VERDANT_CONFIGS_CANON:-/usr/share/verdant/configs}"
LEDGER="${VERDANT_CONFIGS_LEDGER:-${HOME}/.config/verdant/configs}"
XDG_UMBRIEL="${VERDANT_XDG_UMBRIEL:-/etc/xdg/umbriel}"
KEEP_BACKUPS=3
TS="$(date +%Y%m%d-%H%M%S)"

die() { echo "ERROR: $*" >&2; exit 1; }

# Managed set: "<canonical-relative-path>|<user-home-relative-path>".
# Umbriel files are managed only while a user config exists (opt-in via
# customize-umbriel, or the one-time migration of the old skel-baked copy).
UMBRIEL_FILES=("umbriel/config.toml|.config/umbriel/config.toml"
               "umbriel/noctalia.toml|.config/umbriel/noctalia.toml")
NOCTALIA_FILES=("noctalia/settings.toml|.local/state/noctalia/settings.toml"
                "noctalia/palettes/VerdantBrutalistTheme.json|.config/noctalia/palettes/VerdantBrutalistTheme.json"
                "noctalia/plugins/keymap/plugin.toml|.local/share/noctalia/plugins/keymap/plugin.toml"
                "noctalia/plugins/keymap/widget.luau|.local/share/noctalia/plugins/keymap/widget.luau"
                "noctalia/plugins/keymap/service.luau|.local/share/noctalia/plugins/keymap/service.luau"
                "noctalia/plugins/keymap/panel.luau|.local/share/noctalia/plugins/keymap/panel.luau")
# One-time migration merge base (transition release only, removed later).
ARCHIVE_PREFIX="archive/v1"

img_version() { cat "$CANON/VERSION" 2>/dev/null || die "canonical tree missing: $CANON"; }
applied_version() { cat "$LEDGER/applied-version" 2>/dev/null; }
has_ledger() { [ -f "$LEDGER/applied-version" ]; }
interactive() { [ -t 0 ] && [ -z "${CI:-}" ]; }

# --- locking (§6.6): mkdir-based mutex; no stale-lock detection in v1 ------
acquire_lock() {
  mkdir -p "$LEDGER"
  if ! mkdir "$LEDGER/.lock" 2>/dev/null; then
    die "another config operation is running (stale lock? remove $LEDGER/.lock)"
  fi
  trap 'rmdir "$LEDGER/.lock" 2>/dev/null || true' EXIT
}
release_lock() { rmdir "$LEDGER/.lock" 2>/dev/null || true; }

# --- backup retention (E10): keep the last KEEP_BACKUPS per pattern --------
prune_backups() {
  local dir="$1" base="$2" pat="$3" n
  n=$(ls -1t "$dir/${base}.${pat}-"* 2>/dev/null | wc -l)
  if [ "$n" -gt "$KEEP_BACKUPS" ]; then
    ls -1t "$dir/${base}.${pat}-"* 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | while read -r f; do
      rm -f "$f"
    done
  fi
}

# --- ledger -----------------------------------------------------------------
# Baseline snapshot: only files that currently exist are snapshotted.
write_baseline() {
  local rel_user="$1"
  local src="${HOME}/$rel_user"
  local dst="$LEDGER/baseline/$rel_user"
  if [ -L "$src" ]; then
    return 0   # symlinks are never managed (E1)
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
  fi
}

seed_ledger() {
  local v; v="$(img_version)"
  mkdir -p "$LEDGER/baseline"
  local entry rel_user
  for entry in "${NOCTALIA_FILES[@]}"; do
    rel_user="${entry#*|}"
    write_baseline "$rel_user"
  done
  if [ -e "${HOME}/.config/umbriel/config.toml" ]; then
    for entry in "${UMBRIEL_FILES[@]}"; do
      rel_user="${entry#*|}"
      write_baseline "$rel_user"
    done
  fi
  echo "$v" > "$LEDGER/applied-version"
}

# Ledger for a single file (ledger invariant: whatever wrote the user file
# records the baseline). Used by restore-* and customize-umbriel.
ledger_file() {
  local rel_user="$1"
  local src="${HOME}/$rel_user"
  local dst="$LEDGER/baseline/$rel_user"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$src" ] && [ ! -L "$src" ]; then
    cp -f "$src" "$dst"
  else
    rm -f "$dst"
  fi
}

cmd_ledger_file() {
  local p="${1:-}"
  [ -n "$p" ] || die "usage: ledger-file <path>"
  case "$p" in
    "$HOME"/*) : ;;
    *) die "path must be under \$HOME: $p" ;;
  esac
  acquire_lock
  ledger_file "${p#"$HOME"/}"
  release_lock
}

# --- managed file resolution ----------------------------------------------
# Echoes "<canonical-relpath>|<user-relpath>" lines for the files to manage.
managed_files() {
  local entry
  for entry in "${NOCTALIA_FILES[@]}"; do
    echo "$entry"
  done
  if [ -e "${HOME}/.config/umbriel/config.toml" ]; then
    for entry in "${UMBRIEL_FILES[@]}"; do
      echo "$entry"
    done
  fi
}

# --- reloads (E12: guards no-op with a log-out/in hint; never restart the
#     compositor from inside the session) -----------------------------------
reload_umbriel() {
  if pgrep -x umbriel >/dev/null 2>&1 && umbriel msg config-reload 2>/dev/null; then
    echo "umbriel: config reloaded"
  else
    echo "umbriel: reload not possible — log out and back in if changes don't appear"
  fi
}
reload_noctalia() {
  command -v noctalia >/dev/null || return 0
  if pgrep -x noctalia >/dev/null 2>&1; then
    if noctalia msg config-reload 2>/dev/null; then
      echo "noctalia: config reloaded"
    else
      echo "noctalia: reload failed — try: pkill noctalia && noctalia -d"
    fi
  else
    echo "noctalia: not running — starting a fresh instance"
    noctalia -d
  fi
}

# --- 3-way merge (§6.4) ----------------------------------------------------
# merge_file <user-path> <baseline-path> <canonical-path>
# Returns: 0 clean (result written to user path), 1 conflict (marked file at
# <user>.merge-<TS>), 2 unavailable (no git / error).
PENDING_MERGES=()
merge_file() {
  local user="$1" base="$2" canon="$3"
  local merged="${user}.merge-${TS}"
  if ! command -v git >/dev/null; then
    return 2   # E2: merges unavailable
  fi
  local status=0
  git merge-file -p --diff3 "$user" "$base" "$canon" > "$merged" || status=$?
  if [ "$status" -eq 0 ]; then
    if ! cp -f "$merged" "$user"; then
      rm -f "$merged"
      return 3   # E3: write failed (read-only HOME?)
    fi
    rm -f "$merged"
    return 0
  fi
  if [ "$status" -ge 125 ]; then
    rm -f "$merged"
    return 2   # E2: treat like non-interactive conflict
  fi
  # Conflict: back up the original, keep the marked file for resolution.
  local bak="${user}.local-${TS}"
  cp -f "$user" "$bak"
  prune_backups "$(dirname "$user")" "$(basename "$user")" "local"
  PENDING_MERGES+=("$merged")
  return 1
}

# Conflict prompt (§6.4). resolve_conflict <user-path> <merge-file> <canonical-path>
resolve_conflict() {
  local user="$1" merged="$2" canon="$3"
  local ans ans2
  if ! interactive; then
    # Non-interactive: keep mine; the pending merge file is reported at the end.
    return 0
  fi
  while true; do
    read -r -p "$(basename "$user"): conflicting hunks — [r]esolve now (opens $(basename "$merged")) / [t]ake theirs / [k]eep mine? " ans || ans="k"
    case "$ans" in
      r|R)
        if command -v xdg-open >/dev/null && xdg-open "$merged" 2>/dev/null; then
          read -r -p "Edit $(basename "$merged") and save it as $(basename "$user"), then press enter (or type k = keep mine / t = take theirs)" ans2 || ans2=""
          case "$ans2" in
            t|T) cp -f "$canon" "$user"; rm -f "$merged"; return 0 ;;
          esac
          # Empty/other: if the user file is unchanged since the backup,
          # nothing was saved — don't discard the marked merge file.
          if [ -f "${user}.local-${TS}" ] && cmp -s "$user" "${user}.local-${TS}"; then
            echo "no changes detected — keeping the merge file; choose again"
            continue
          fi
          rm -f "$merged"
          return 0
        else
          echo "could not open $merged — edit it manually (then enter), or pick t/k"
        fi
        ;;
      t|T)
        cp -f "$canon" "$user"
        rm -f "$merged"
        return 0 ;;
      k|K|""|*)
        # Keep mine — the marked merge file stays as the pending artifact
        # (reported at the end) so the user can resolve it later.
        return 0 ;;
    esac
  done
}

# --- per-file upgrade logic (§6.2 decision table) ---------------------------
UPD=()      # user-relative paths that changed (drives reload decision)
REPORT=()   # final report lines
CHANGED=0
FORCE=0

# process_file <canonical-relpath> <user-relpath>
process_file() {
  local canon_rel="$1" user_rel="$2"
  local canon="$CANON/$canon_rel"
  local user="${HOME}/${user_rel}"
  local base="$LEDGER/baseline/$user_rel"

  [ -f "$canon" ] || return 0    # removed upstream — handled by the E8 pass

  # E1: symlinks are never managed
  if [ -L "$user" ]; then
    REPORT+=("skip: ${user_rel} is a symlink — left untouched")
    return 0
  fi

  local user_exists=0
  [ -e "$user" ] && user_exists=1
  local base_exists=0
  [ -f "$base" ] && base_exists=1

  if [ "$user_exists" -eq 0 ]; then
    if [ "$base_exists" -eq 1 ]; then
      # Row 2: user deleted a managed file (D6/E9)
      if [ "$FORCE" -eq 1 ]; then
        mkdir -p "$(dirname "$user")"
        cp -f "$canon" "$user"
        REPORT+=("reinstalled: ${user_rel} (--force)")
        CHANGED=1
        UPD+=("$user_rel")
      else
        REPORT+=("skip: ${user_rel} — you removed it; re-install with: just upgrade-configs --force")
      fi
      return 0
    fi
    # Row 1: new upstream file
    mkdir -p "$(dirname "$user")"
    if ! cp -f "$canon" "$user"; then
      REPORT+=("failed: ${user_rel} — could not write (read-only HOME?)")
      return 0
    fi
    REPORT+=("installed: ${user_rel} (new in this release)")
    CHANGED=1
    UPD+=("$user_rel")
    return 0
  fi

  if [ "$base_exists" -eq 0 ]; then
    # Row 3: user file with no upstream baseline — adopt, never overwrite
    REPORT+=("kept: ${user_rel} (your version, no upstream baseline)")
    return 0
  fi

  if cmp -s "$user" "$base"; then
    # Row 4: untouched — auto-update (the baseline IS the old content)
    if cmp -s "$user" "$canon"; then
      REPORT+=("ok: ${user_rel} already up to date")
      return 0
    fi
    # E7: re-check immediately before writing
    if ! cmp -s "$user" "$base"; then
      REPORT+=("changed while running: ${user_rel} — will merge instead")
    else
      if ! cp -f "$canon" "$user"; then
        REPORT+=("failed: ${user_rel} — could not write (read-only HOME?)")
        return 0
      fi
      REPORT+=("updated: ${user_rel}")
      CHANGED=1
      UPD+=("$user_rel")
      return 0
    fi
  fi

  # Row 5: local changes — 3-way merge
  local rc=0
  merge_file "$user" "$base" "$canon" || rc=$?
  if [ "$rc" -eq 0 ]; then
    REPORT+=("merged: ${user_rel} (your local changes kept)")
    CHANGED=1
    UPD+=("$user_rel")
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    REPORT+=("failed: ${user_rel} — merge ready but could not write (read-only HOME?)")
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    # E2 / git error: binary choice
    REPORT+=("conflict: ${user_rel} — merge unavailable")
    if interactive; then
      read -r -p "  [t]ake theirs (image) / [k]eep yours? " ans || ans="k"
      case "$ans" in
        t|T) cp -f "$canon" "$user"; REPORT+=("took theirs: ${user_rel}"); CHANGED=1; UPD+=("$user_rel") ;;
        *) REPORT+=("kept yours: ${user_rel}") ;;
      esac
    else
      REPORT+=("kept yours: ${user_rel} (non-interactive)")
    fi
    return 0
  fi
  # rc == 1: conflict with pending merge file
  local merged="${user}.merge-${TS}"
  resolve_conflict "$user" "$merged" "$canon"
  REPORT+=("conflict: ${user_rel} — see $(basename "$merged")")
}

# --- §7 one-time Umbriel migration (existing users, transition release) -----
# The old skel-baked user config shadows /etc/xdg/umbriel. archive/v1 is the
# exact config those users were shipped, so it is a true merge base.
migrate_umbriel() {
  local canon="$1" user="$2"
  local rel_user="${user#"$HOME"/}"
  local archive="$CANON/${ARCHIVE_PREFIX}/${canon#"$CANON"/}"
  local base_label=""
  if [ -f "$archive" ]; then
    base_label="$archive"
  fi

  if [ -n "$base_label" ] && cmp -s "$user" "$base_label"; then
    # Case 2: user config identical to what they were shipped
    if interactive; then
      read -r -p "$(basename "$user") matches your original Verdant config — [d]elete it and fall back to the system config (recommended, auto-updates) / [k]eep a copy? " ans || ans="k"
      case "$ans" in
        d|D)
          rm -f "$user"
          ledger_file "$rel_user"   # removes the baseline entry
          REPORT+=("migrated: removed ${rel_user} — running on system config (${XDG_UMBRIEL})")
          CHANGED=1
          return 0 ;;
        *)
          REPORT+=("migrated: kept ${rel_user} (baseline = original, will merge forward)")
          CHANGED=1
          return 0 ;;
      esac
    else
      REPORT+=("migrated: kept ${rel_user} (non-interactive — run interactively to opt into the system config)")
      CHANGED=1
      return 0
    fi
  fi

  if [ -n "$base_label" ]; then
    # Case 3: user modified their config -> 3-way merge against the original
    local rc=0
    merge_file "$user" "$base_label" "$canon" || rc=$?
    if [ "$rc" -eq 0 ]; then
      REPORT+=("migrated: merged ${rel_user} (your changes kept, baseline = original)")
      CHANGED=1
      return 0
    fi
    if [ "$rc" -eq 1 ]; then
      local merged="${user}.merge-${TS}"
      resolve_conflict "$user" "$merged" "$canon"
      REPORT+=("migrated: conflict in ${rel_user} — see $(basename "$merged")")
      CHANGED=1
      return 0
    fi
  fi
  # Case 4: no archive (image past the transition) — binary choice, never guess
  REPORT+=("migrated: no original on record for ${rel_user}")
  if command -v diff >/dev/null; then
    diff -u "$user" "$canon" || true
  fi
  if interactive; then
    read -r -p "  [t]ake theirs (image) / [k]eep yours? " ans || ans="k"
    case "$ans" in
      t|T) cp -f "$canon" "$user"; REPORT+=("took theirs: ${rel_user}"); CHANGED=1 ;;
      *) REPORT+=("kept yours: ${rel_user}") ;;
    esac
  else
    REPORT+=("kept yours: ${rel_user} (non-interactive)")
  fi
}

# --- subcommands ------------------------------------------------------------

cmd_seed() {
  acquire_lock
  seed_ledger
  local v; v="$(img_version)"
  echo "Baseline established from your current config (v$v)."
  echo "Future updates merge against it. To sync to the current Verdant defaults now:"
  echo "  diff -ru <your file> $CANON/<relpath>"
  echo "or hard-reset everything: just restore-config"
  echo "No files were changed."
}

cmd_check() {
  acquire_lock
  mkdir -p "$LEDGER"
  if ! has_ledger; then
    seed_ledger
    echo "First run — baseline established (v$(img_version))."
    if [ -e "${HOME}/.config/umbriel/config.toml" ]; then
      local archive="$CANON/${ARCHIVE_PREFIX}/umbriel/config.toml"
      if [ -f "$archive" ]; then
        if cmp -s "${HOME}/.config/umbriel/config.toml" "$archive"; then
          echo "Umbriel migration pending: your config matches the original — upgrade will offer to fall back to the system config."
        else
          echo "Umbriel migration pending: your config has local changes — upgrade will merge them against the original."
        fi
      else
        echo "Umbriel migration pending: no original on record — upgrade will offer a per-file keep/take choice."
      fi
    fi
    echo "Re-run: just check-configs"
    release_lock
    exit 0
  fi
  local img applied
  img="$(img_version)"; applied="$(applied_version)"
  if [ "$img" = "$applied" ]; then
    echo "Up to date (v$applied)."
    release_lock
    exit 0
  fi
  echo "Config update available: v$applied -> v$img"
  local entry canon_rel user_rel
  local would=0
  local -a entries=()
  while IFS= read -r entry; do entries+=("$entry"); done < <(managed_files)
  for entry in "${entries[@]}"; do
    IFS='|' read -r canon_rel user_rel <<< "$entry"
    local canon="$CANON/$canon_rel" user="${HOME}/${user_rel}" base="$LEDGER/baseline/$user_rel"
    [ -f "$canon" ] || continue
    if [ -L "$user" ]; then
      echo "  ${user_rel}: local change (symlink — left untouched)"
      continue
    fi
    if [ ! -e "$user" ]; then
      if [ -f "$base" ]; then
        echo "  ${user_rel}: removed by you (re-install with: just upgrade-configs --force)"
      else
        echo "  ${user_rel}: will-install (new in this release)"
        would=1
      fi
      continue
    fi
    if [ ! -f "$base" ]; then
      echo "  ${user_rel}: local change (no upstream baseline)"
      continue
    fi
    if cmp -s "$user" "$base"; then
      if cmp -s "$user" "$canon"; then
        echo "  ${user_rel}: ok"
      else
        echo "  ${user_rel}: auto-update (no local changes)"
        would=1
      fi
    else
      echo "  ${user_rel}: local changes (will merge)"
      would=1
    fi
  done
  if [ "$would" -eq 0 ]; then
    echo "No file changes pending — version ledger only."
  fi
  echo "Apply: just upgrade-configs"
  release_lock
  exit 10
}

cmd_upgrade() {
  FORCE=0
  if [ "${1:-}" = "--force" ]; then FORCE=1; fi
  acquire_lock
  mkdir -p "$LEDGER"
  local img; img="$(img_version)"

  if ! has_ledger; then
    # First run (D5): seed-only, non-destructive. The one-time Umbriel
    # migration (§7) is the exception — it has a true merge base.
    local migrating=0
    [ -e "${HOME}/.config/umbriel/config.toml" ] && migrating=1
    seed_ledger
    local entry ur
    if [ "$migrating" -eq 1 ]; then
      for entry in "${UMBRIEL_FILES[@]}"; do
        ur="${entry#*|}"
        if [ -e "${HOME}/${ur}" ]; then
          migrate_umbriel "$CANON/${entry%%|*}" "${HOME}/${ur}"
        fi
      done
    fi
    # Ledger invariant: baseline mirrors the user files as they now stand
    for entry in "${NOCTALIA_FILES[@]}"; do
      IFS='|' read -r _ ur <<< "$entry"
      if [ -e "${HOME}/${ur}" ] && [ ! -L "${HOME}/${ur}" ]; then
        ledger_file "$ur"
      fi
    done
    if [ -e "${HOME}/.config/umbriel/config.toml" ]; then
      for entry in "${UMBRIEL_FILES[@]}"; do
        ur="${entry#*|}"
        ledger_file "$ur"
      done
    fi
    if [ "$CHANGED" -eq 1 ] && [ -e "${HOME}/.config/umbriel/config.toml" ]; then
      reload_umbriel
    fi
    for line in "${REPORT[@]}"; do
      echo "  $line"
    done
    echo "First run — baseline established (v$img)."
    echo "No auto-updates were applied. To sync to the current Verdant defaults now:"
    echo "  diff -ru <your file> $CANON/<relpath>   or   just restore-config"
    echo "Re-run: just upgrade-configs"
    release_lock
    exit 0
  fi

  local applied; applied="$(applied_version)"
  if [ "$img" = "$applied" ] && [ "$FORCE" -ne 1 ]; then
    echo "Up to date (v$applied)."
    release_lock
    exit 0
  fi
  if [ "$img" = "$applied" ]; then
    echo "Re-applying v$img (--force)"
  else
    echo "Upgrading config: v$applied -> v$img"
  fi
  local entry
  local -a entries=()
  while IFS= read -r entry; do entries+=("$entry"); done < <(managed_files)
  for entry in "${entries[@]}"; do
    local canon_rel user_rel
    IFS='|' read -r canon_rel user_rel <<< "$entry"
    process_file "$canon_rel" "$user_rel"
  done

  # E8: files in the baseline but no longer in the managed set (removed upstream)
  local f rel known
  if [ -d "$LEDGER/baseline" ]; then
    while IFS= read -r f; do
      rel="${f#"$LEDGER"/baseline/}"
      known=0
      for entry in "${NOCTALIA_FILES[@]}" "${UMBRIEL_FILES[@]}"; do
        if [ "${entry#*|}" = "$rel" ]; then known=1; break; fi
      done
      if [ "$known" -eq 0 ]; then
        REPORT+=("no longer managed: ${rel} (removed upstream — your file stays)")
        rm -f "$f"   # one-time report: drop the stale baseline entry
      fi
    done < <(find "$LEDGER/baseline" -type f 2>/dev/null)
  fi

  for line in "${REPORT[@]}"; do
    echo "  $line"
  done

  if [ "$CHANGED" -eq 1 ]; then
    # Ledger invariant: baseline mirrors the user files as they now stand.
    # Entries for user-deleted files are kept — that is what row 2 (D6)
    # reports against on future upgrades.
    while IFS='|' read -r cr ur; do
      if [ -e "${HOME}/${ur}" ] && [ ! -L "${HOME}/${ur}" ]; then
        ledger_file "$ur"
      fi
    done < <(managed_files)
    echo "$img" > "$LEDGER/applied-version"
    local umbriel_touched=0 noctalia_touched=0 rel2
    for rel2 in "${UPD[@]}"; do
      case "$rel2" in
        .config/umbriel/*) umbriel_touched=1 ;;
        *) noctalia_touched=1 ;;
      esac
    done
    if [ "$umbriel_touched" -eq 1 ]; then reload_umbriel; fi
    if [ "$noctalia_touched" -eq 1 ]; then reload_noctalia; fi
  else
    # No file changes, but the config now corresponds to the new version
    echo "$img" > "$LEDGER/applied-version"
  fi

  if [ "${#PENDING_MERGES[@]}" -gt 0 ]; then
    echo
    echo "Pending merge files (resolve, then save over the original):"
    for m in "${PENDING_MERGES[@]}"; do
      echo "  $m"
    done
  fi
  echo "Done."
  release_lock
}

cmd_customize_umbriel() {
  acquire_lock
  mkdir -p "$LEDGER"
  if [ -e "${HOME}/.config/umbriel/config.toml" ]; then
    die "user config exists — edit it or run: just restore-umbriel first"
  fi
  [ -f "${XDG_UMBRIEL}/config.toml" ] || die "system config missing: ${XDG_UMBRIEL}/config.toml"
  mkdir -p "${HOME}/.config/umbriel"
  cp -f "${XDG_UMBRIEL}/config.toml" "${XDG_UMBRIEL}/noctalia.toml" "${HOME}/.config/umbriel/"
  if has_ledger; then
    # Existing ledger: only the umbriel entries are new
    ledger_file ".config/umbriel/config.toml"
    ledger_file ".config/umbriel/noctalia.toml"
  else
    seed_ledger   # baseline := the copies, applied := image VERSION
  fi
  echo "Created ~/.config/umbriel/ from the system config — it now shadows ${XDG_UMBRIEL}."
  echo "Edit it freely; future updates merge against your version."
  reload_umbriel
  release_lock
}

cmd_notify_check() {
  local img; img="$(img_version)"
  mkdir -p "$LEDGER"
  local applied
  if ! applied="$(cat "$LEDGER/applied-version" 2>/dev/null)"; then
    seed_ledger    # new user: silent seed, no nag
    exit 0
  fi
  local notified
  notified="$(cat "$LEDGER/notified-version" 2>/dev/null || echo 0)"
  if [ "$img" != "$applied" ] && [ "$img" != "$notified" ]; then
    if command -v notify-send >/dev/null; then
      notify-send -a "Verdant" "Verdant config update available (v$applied → v$img)" "Run: just upgrade-configs"
    fi
    echo "$img" > "$LEDGER/notified-version"
  fi
  exit 0
}

# --- dispatch ---------------------------------------------------------------
cmd="${1:-help}"
shift || true
case "$cmd" in
  seed)                cmd_seed "$@" ;;
  check)               cmd_check "$@" ;;
  upgrade)             cmd_upgrade "$@" ;;
  customize-umbriel)   cmd_customize_umbriel "$@" ;;
  notify-check)        cmd_notify_check "$@" ;;
  ledger-file)         cmd_ledger_file "$@" ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    echo "usage: $0 {seed|check|upgrade|customize-umbriel|notify-check|ledger-file <path>}"
    echo "exit codes: check → 0 = up to date, 10 = updates available"
    exit 2 ;;
esac
