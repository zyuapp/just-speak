#!/bin/sh
# Install the latest Just Speak release.
#
#   curl -fsSL https://raw.githubusercontent.com/zyuapp/just-speak/main/install.sh | sh
#
# Puts the notarized app in /Applications (or ~/Applications when that is not writable).
set -eu

REPO="zyuapp/just-speak"
DOWNLOAD="https://github.com/$REPO/releases/latest/download"
APP="Just Speak.app"

fail() { printf '\nInstall failed: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || fail "Just Speak runs on macOS only."
arch="$(uname -m)"
if [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then arch=arm64; fi
[ "$arch" = arm64 ] || fail "Just Speak needs a Mac with Apple silicon, and this Mac is $arch."
os="$(sw_vers -productVersion)"
major="$(echo "$os" | cut -d. -f1)"
minor="$(echo "$os" | cut -d. -f2)"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 6 ]; }; then
  fail "Just Speak needs macOS 14.6 or later, and this Mac has $os."
fi
command -v curl >/dev/null 2>&1 || fail "curl is required."

applications=/Applications
[ -w "$applications" ] || applications="$HOME/Applications"
mkdir -p "$applications"

# Stage inside the destination so the final move is a rename on the same filesystem.
staging="$applications/.just-speak-install.$$"
rm -rf "$staging"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT INT TERM

say "Downloading Just Speak."
curl -fL --retry 3 --progress-bar -o "$staging/JustSpeak.zip" "$DOWNLOAD/JustSpeak.zip" \
  || fail "The download did not finish."
expected="$(curl -fsSL "$DOWNLOAD/JustSpeak.zip.sha256" | cut -d' ' -f1)" \
  || fail "Could not read the checksum of the latest release."
[ "$(shasum -a 256 "$staging/JustSpeak.zip" | cut -d' ' -f1)" = "$expected" ] \
  || fail "The download did not match its checksum. Try again."

if pgrep -f "/$APP/Contents/MacOS/JustSpeak" >/dev/null 2>&1; then
  fail "Just Speak is running. Quit it from the menu bar, then run this again."
fi
/usr/bin/ditto -x -k "$staging/JustSpeak.zip" "$staging/unpacked" || fail "The download could not be unpacked."
[ -d "$staging/unpacked/$APP" ] || fail "The download contained no app."
target="$applications/$APP"
rm -rf "$target"
mv "$staging/unpacked/$APP" "$target"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo latest)"
say "Installed Just Speak $version in $target"

open -a "$target"
