#!/bin/sh
# Islet installer: curl -fsSL https://yashtygi.github.io/islet/install.sh | sh
#
# Downloads the latest Islet.dmg from GitHub Releases, checks its SHA-256 against the
# published Islet.dmg.sha256, copies Islet.app into /Applications and opens it.
# Nothing else is changed: no sudo, no PATH edits, no Claude hooks. Islet's own
# onboarding asks for those, so you see and approve each one.
#
# Testing: ISLET_BASE=<url or file://dir> overrides the download location; ISLET_DEST=<path>
# installs somewhere other than /Applications and skips opening the app.

set -eu

main() {
  base="${ISLET_BASE:-https://github.com/YashTygi/islet/releases/latest/download}"
  dest="${ISLET_DEST:-/Applications/Islet.app}"

  say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
  die() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

  [ "$(uname -s)" = "Darwin" ] || die "Islet runs on macOS only."
  [ "$(uname -m)" = "arm64" ] || die "Islet needs an Apple silicon Mac (M1 or later)."
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || die "Islet needs macOS 14 or later (you have $(sw_vers -productVersion))."

  tmp="$(mktemp -d -t islet)"
  mnt="$tmp/mnt"
  cleanup() { hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"; }
  trap cleanup EXIT INT TERM

  say "Downloading Islet…"
  curl -fsSL -o "$tmp/Islet.dmg" "$base/Islet.dmg" || die "Download failed. Check your connection and try again."
  curl -fsSL -o "$tmp/Islet.dmg.sha256" "$base/Islet.dmg.sha256" || die "Couldn't download the checksum, so the install was stopped."

  say "Checking the download…"
  want="$(awk '{print $1; exit}' "$tmp/Islet.dmg.sha256")"
  got="$(shasum -a 256 "$tmp/Islet.dmg" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || die "Checksum mismatch. The download may be damaged or tampered with; nothing was installed."

  mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/Islet.dmg" -quiet || die "Couldn't open the disk image."
  [ -d "$mnt/Islet.app" ] || die "Islet.app wasn't found in the disk image."

  if [ -z "${ISLET_DEST:-}" ] && pgrep -xq Islet; then
    say "Quitting the running Islet…"
    osascript -e 'tell application id "com.yashtyagi.Islet" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -x Islet 2>/dev/null || true
  fi

  [ -w "$(dirname "$dest")" ] || die "Can't write to /Applications. Download the DMG from https://yashtygi.github.io/islet/ instead."
  say "Installing to $dest…"
  rm -rf "$dest"
  ditto "$mnt/Islet.app" "$dest" || die "Copying Islet.app failed."

  [ -z "${ISLET_DEST:-}" ] || { say "Installed (test mode, not opened)."; return; }
  say "Opening Islet. Follow the setup window to finish."
  open "$dest"
  printf '\nDone. Look at the notch at the top of your screen.\n'
}

main "$@"
