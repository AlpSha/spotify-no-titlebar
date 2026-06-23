#!/usr/bin/env bash
# cef_noframe installer — builds the shim and wires it into a per-user
# Spotify launcher so the CEF white title bar is gone on every launch.
#
# Env overrides:
#   PREFIX=~/.local            install prefix for the .so
#   SPOTIFY_DESKTOP=/path.desktop   base launcher to derive from
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
LIBDIR="$PREFIX/lib"
SO_PATH="$LIBDIR/cef-noframe.so"
APP_DIR="$HOME/.local/share/applications"

# CEF branch (= chromium build number, 3rd version field) the shim's
# default offsets were derived for.
SUPPORTED_BRANCH="7559"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v cc >/dev/null 2>&1 || die "a C compiler (cc/gcc) is required"

# --- locate libcef.so to report the CEF/chromium version ------------------
CEF_LIB=""
for p in /opt/spotify/libcef.so /usr/share/spotify/libcef.so \
         /usr/lib/spotify/libcef.so \
         "$HOME/.local/share/spotify-launcher/install/usr/share/spotify/libcef.so"; do
  [ -e "$p" ] && { CEF_LIB="$p"; break; }
done

if [ -n "$CEF_LIB" ]; then
  CHROMIUM_VER="$(strings "$CEF_LIB" 2>/dev/null | grep -oE 'chromium-[0-9.]+' | head -1 | sed 's/chromium-//')"
  CEF_BRANCH="$(printf '%s\n' "$CHROMIUM_VER" | cut -d. -f3)"
  say "Detected Spotify CEF build: chromium-${CHROMIUM_VER:-unknown} (CEF branch ${CEF_BRANCH:-?})"
  if [ -n "$CEF_BRANCH" ] && [ "$CEF_BRANCH" != "$SUPPORTED_BRANCH" ]; then
    warn "Built-in offsets target CEF branch $SUPPORTED_BRANCH; yours is $CEF_BRANCH."
    warn "It may still work (offsets only move on bigger CEF jumps). If the bar"
    warn "stays, see README 'Recomputing offsets' / use CEF_NOFRAME_DEBUG=1."
  fi
else
  warn "Could not find libcef.so (non-standard Spotify install?). Continuing anyway."
fi

# --- build ----------------------------------------------------------------
say "Building shim -> $SO_PATH"
mkdir -p "$LIBDIR"
cc -shared -fPIC -O2 -o "$SO_PATH" "$REPO_DIR/src/cef_noframe.c" -ldl
say "Built $(du -h "$SO_PATH" | cut -f1) shared object"

# --- find a base .desktop to derive the launcher from ---------------------
# Covers the AUR `spotify`/official .deb (spotify.desktop), the
# `spotify-launcher` package (spotify-launcher.desktop), and snap.
BASE_DESKTOP="${SPOTIFY_DESKTOP:-}"
if [ -z "$BASE_DESKTOP" ]; then
  for d in /usr/share/applications/spotify.desktop \
           /usr/local/share/applications/spotify.desktop \
           /usr/share/applications/spotify-launcher.desktop \
           /usr/local/share/applications/spotify-launcher.desktop \
           /var/lib/snapd/desktop/applications/spotify_spotify.desktop; do
    [ -e "$d" ] && { BASE_DESKTOP="$d"; break; }
  done
fi

mkdir -p "$APP_DIR"
# Shadow the system entry by reusing its basename, so we don't end up with a
# duplicate "Spotify" item in the app menu next to the stock one.
if [ -n "$BASE_DESKTOP" ]; then
  OUT_DESKTOP="$APP_DIR/$(basename "$BASE_DESKTOP")"
else
  OUT_DESKTOP="$APP_DIR/spotify.desktop"
fi

if [ -n "$BASE_DESKTOP" ] && [ -e "$BASE_DESKTOP" ]; then
  say "Deriving launcher from $BASE_DESKTOP"
  # Prefix every Exec= line with the LD_PRELOAD env, add an uninstall marker.
  awk -v so="$SO_PATH" '
    /^Exec=/ && $0 !~ /cef-noframe\.so/ { sub(/^Exec=/, "Exec=env LD_PRELOAD=" so " ") }
    { print }
    END { print "X-CefNoframe=1" }
  ' "$BASE_DESKTOP" > "$OUT_DESKTOP"
else
  warn "No system spotify.desktop found; writing a minimal launcher."
  # Prefer spotify-launcher if present (it execs the real spotify binary, and
  # LD_PRELOAD is inherited by that child), else fall back to a bare spotify.
  if command -v spotify-launcher >/dev/null 2>&1; then
    SPOTIFY_CMD="spotify-launcher"; SPOTIFY_TRYEXEC="spotify-launcher"; SPOTIFY_ARGS="%U"
  else
    SPOTIFY_CMD="spotify"; SPOTIFY_TRYEXEC="spotify"; SPOTIFY_ARGS="--uri=%u"
  fi
  cat > "$OUT_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Spotify
GenericName=Music Player
Icon=spotify-client
TryExec=$SPOTIFY_TRYEXEC
Exec=env LD_PRELOAD=$SO_PATH $SPOTIFY_CMD $SPOTIFY_ARGS
Terminal=false
MimeType=x-scheme-handler/spotify;
Categories=Audio;Music;Player;AudioVideo;
StartupWMClass=spotify
X-CefNoframe=1
EOF
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true

say "Installed launcher -> $OUT_DESKTOP"
echo
say "Done. Fully quit Spotify (pkill -f spotify) and relaunch it from your"
say "app launcher / menu. The white title bar should be gone."
echo
if command -v spotify-launcher >/dev/null 2>&1; then
  warn "Note: launching bare 'spotify-launcher' from a terminal bypasses this .desktop."
  warn "For that, run:  LD_PRELOAD=$SO_PATH spotify-launcher"
  warn "or add a shell alias (see README)."
else
  warn "Note: launching bare 'spotify' from a terminal bypasses this .desktop."
  warn "For that, run:  LD_PRELOAD=$SO_PATH spotify"
  warn "or add a shell alias (see README)."
fi
