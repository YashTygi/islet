#!/bin/sh
# Islet uninstaller: curl -fsSL https://yashtygi.github.io/islet/uninstall.sh | sh
#
# Removes everything Islet adds to a Mac: the app, the `islet` command, its ~/.zshrc PATH
# line, Claude Code hooks, the Codex notify line, settings, data, caches and its macOS
# privacy permissions. Files go to the Trash (in one "Islet uninstall" folder), not deleted,
# and every config file it edits is backed up there first. Nothing else is touched:
# the GitHub CLI and your other Claude/Codex settings stay as they are.
#
# Testing: ISLET_HOME=<dir> runs against a fake home folder and skips quitting the app,
# /Applications and the permission reset.

set -eu

main() {
  home="${ISLET_HOME:-$HOME}"
  test_mode="${ISLET_HOME:+1}"
  id="com.yashtyagi.Islet"
  trash="$home/.Trash/Islet uninstall $(date +%Y-%m-%d_%H%M%S)"
  removed=0

  say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
  [ "$(uname -s)" = "Darwin" ] || { echo "Islet is a macOS app; nothing to do here."; exit 0; }
  mkdir -p "$trash"

  # Move one path to the Trash folder, keeping a readable name.
  bin() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    name="$(printf '%s' "$1" | sed "s#^$home#~#; s#/#_#g; s#^_##")"
    mv "$1" "$trash/$name" && say "Moved to Trash: $1" && removed=$((removed + 1))
  }
  backup() { [ -f "$1" ] && cp "$1" "$trash/$(basename "$1").before-uninstall"; }

  if [ -z "$test_mode" ] && pgrep -xq Islet; then
    say "Quitting Islet…"
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    sleep 2
  fi
  [ -n "$test_mode" ] || { pkill -x Islet 2>/dev/null || true; pkill -f 'Islet.app/Contents/Resources/mediaremote-adapter' 2>/dev/null || true; }

  # The `islet` command: only symlinks that point into an Islet (or old MyNotch) app.
  for dir in "$home/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [ -n "$test_mode" ] && [ "$dir" != "$home/.local/bin" ] && continue
    for link in "$dir/islet" "$dir/notch"; do
      [ -L "$link" ] || continue
      case "$(readlink "$link")" in
        *Islet.app/Contents/Helpers/islet|*/Contents/MacOS/notch) bin "$link" ;;
      esac
    done
  done

  # ~/.zshrc: Islet's marked PATH line. Removed when it points into Islet.app; if it added a
  # shared folder like ~/.local/bin, the line is left (other tools may use it) and noted.
  rc="$home/.zshrc"
  marker='# Added by Islet: makes the `islet` command available'
  if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
    backup "$rc"
    awk -v m="$marker" '
      $0 == m { getline next_line; if (next_line ~ /Islet\.app/) { dropped = 1; next } else { print next_line; kept = 1; next } }
      { print }
      END { if (kept) print "kept" > "/dev/stderr" }' "$rc" > "$rc.islet-tmp" 2> "$trash/.zshrc-note" || true
    mv "$rc.islet-tmp" "$rc"
    if [ -s "$trash/.zshrc-note" ]; then say "Removed Islet's comment from ~/.zshrc (kept its PATH line: other tools may use that folder)."
    else say "Removed Islet's PATH line from ~/.zshrc."; fi
    rm -f "$trash/.zshrc-note"; removed=$((removed + 1))
  fi

  # Claude Code hooks: drop only entries whose command runs Islet. JXA ships with macOS.
  cs="$home/.claude/settings.json"
  if [ -f "$cs" ] && grep -q 'Helpers/islet' "$cs"; then
    backup "$cs"
    osascript -l JavaScript - "$cs" <<'JXA' && say "Removed Islet's Claude Code hooks (other settings kept)." && removed=$((removed + 1))
function run(argv) {
  const path = argv[0];
  const read = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  const s = JSON.parse(ObjC.unwrap(read));
  const ours = e => (e.hooks || []).some(h => /Helpers\/islet/.test(h.command || ""));
  for (const k of Object.keys(s.hooks || {})) {
    const kept = (s.hooks[k] || []).filter(e => !ours(e));
    if (kept.length) s.hooks[k] = kept; else delete s.hooks[k];
  }
  if (s.hooks && !Object.keys(s.hooks).length) delete s.hooks;
  $(JSON.stringify(s, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JXA
  fi
  bin "$home/.claude/settings.json.mynotch-backup"

  # Codex: the notify line pointing at Islet.
  cx="$home/.codex/config.toml"
  if [ -f "$cx" ] && grep -q '^notify.*Helpers/islet' "$cx"; then
    backup "$cx"
    sed -i '' '/^notify.*Helpers\/islet/d' "$cx"
    say "Removed Islet's notify line from ~/.codex/config.toml."; removed=$((removed + 1))
  fi

  # Settings, data and caches (including the old "MyNotch" name).
  if [ -z "$test_mode" ]; then
    defaults delete "$id" >/dev/null 2>&1 || true
    defaults delete com.yashtyagi.MyNotch >/dev/null 2>&1 || true
  fi
  for p in \
    "$home/Library/Preferences/$id.plist" \
    "$home/Library/Preferences/com.yashtyagi.MyNotch.plist" \
    "$home/Library/Application Support/Islet" \
    "$home/Library/Application Support/MyNotch" \
    "$home/Library/Caches/$id" \
    "$home/Library/HTTPStorages/$id" \
    "$home/Library/Saved Application State/$id.savedState" \
    "$home/Applications/Islet.app"; do
    bin "$p"
  done

  # The app itself, then the privacy permissions macOS remembers for it.
  if [ -z "$test_mode" ]; then
    bin "/Applications/Islet.app"
    tccutil reset All "$id" >/dev/null 2>&1 && say "Reset Islet's privacy permissions (Accessibility, Calendar, Camera, Automation)."
  fi

  if [ "$removed" -eq 0 ]; then
    rmdir "$trash" 2>/dev/null || true
    echo "Islet wasn't found on this Mac. Nothing to remove."
  else
    printf '\nIslet is uninstalled. Everything removed is in the Trash, in "%s".\n' "$(basename "$trash")"
    echo "Open a new terminal window so the old PATH is gone."
  fi
}

main "$@"
