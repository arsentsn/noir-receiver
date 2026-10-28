#!/bin/sh
# Installs (or updates) Noir Receiver from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/arsentsn/noir-receiver/main/install.sh | sh
#
# **Why a script and not a download link: Gatekeeper.** The app is not signed with a paid Apple
# Developer ID, and macOS blocks an unsigned app *downloaded by a browser* until the user digs
# through Privacy & Security. The block keys on the quarantine flag browsers attach; curl attaches
# none, so an app fetched here opens like one built locally. Nothing is disabled or bypassed on the
# Mac, and the flag is cleared below only in case a proxy or tool added one.
#
# Re-running it updates in place. NOIR_RECEIVER_URL points it at another zip (a test build).
set -eu

url=${NOIR_RECEIVER_URL:-https://github.com/arsentsn/noir-receiver/releases/latest/download/Noir-Receiver.zip}
app="Noir Receiver.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'Noir Receiver: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "this installs a macOS app; run it on a Mac."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "needs macOS 13 or later (this Mac runs $(sw_vers -productVersion))."

# /Applications for an admin account (the usual case, no password needed), else the user's own.
dest=/Applications
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading Noir Receiver…"
curl -fsSL "$url" -o "$tmp/receiver.zip" || fail "download failed ($url)."
ditto -x -k "$tmp/receiver.zip" "$tmp" || fail "the download is not a valid zip."
[ -d "$tmp/$app" ] || fail "the download does not contain $app."

# A running copy keeps executing the old binary after it is replaced, so quit it first. The quit
# event is the polite way; the menu bar app has no window to object with.
if pgrep -xq "Noir Receiver"; then
  say "Quitting the running copy…"
  osascript -e 'quit app id "me.arsentsn.NoirReceiver"' >/dev/null 2>&1 || true
  i=0
  while pgrep -xq "Noir Receiver" && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  pkill -x "Noir Receiver" 2>/dev/null || true
fi

rm -rf "$dest/$app"
mv "$tmp/$app" "$dest/"
xattr -dr com.apple.quarantine "$dest/$app" 2>/dev/null || true

open "$dest/$app"
version=$(defaults read "$dest/$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
say "Installed Noir Receiver $version in $dest. It lives in the menu bar."
say "If macOS asks to find devices on your local network, click Allow."
