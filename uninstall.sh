#!/usr/bin/env bash
# Reverts what install.sh did. Leaves the system Spotify install untouched.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
SO_PATH="$PREFIX/lib/cef-noframe.so"
APP_DIR="$HOME/.local/share/applications"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [ -e "$SO_PATH" ]; then
  rm -f "$SO_PATH"
  say "Removed $SO_PATH"
fi

# Remove any per-user launcher we generated, identified by the marker — covers
# both spotify.desktop (AUR/.deb) and spotify-launcher.desktop (spotify-launcher).
removed=0
for f in "$APP_DIR"/spotify.desktop "$APP_DIR"/spotify-launcher.desktop; do
  if [ -e "$f" ] && grep -q '^X-CefNoframe=1' "$f"; then
    rm -f "$f"
    say "Removed $f"
    removed=1
  fi
done
if [ "$removed" -eq 1 ]; then
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
else
  say "No tool-generated launcher found in $APP_DIR (nothing to remove)"
fi

say "Uninstalled. Restart Spotify to go back to stock behaviour."
