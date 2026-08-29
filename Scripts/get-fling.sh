#!/usr/bin/env bash
# Installs Fling straight from the repo — no zip, no releases page. Pulls the
# universal binary from bin/ and assembles the .app locally. curl-fetched
# files carry no quarantine attribute, so there is no Gatekeeper dance.
set -euo pipefail

RAW="https://raw.githubusercontent.com/damionrashford/fling/main"
APP="/Applications/Fling.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Fling"
curl -fsSL "$RAW/bin/Fling" -o "$TMP/Fling"
curl -fsSL "$RAW/Resources/Info.plist" -o "$TMP/Info.plist"

echo "==> Installing to $APP"
killall Fling 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$TMP/Fling" "$APP/Contents/MacOS/Fling"
mv "$TMP/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Fling"
# Local ad-hoc signature: macOS always accepts it, and it never carries
# anyone's identity.
codesign --force --deep -s - "$APP"

if [ ! -x "$HOME/.local/bin/catt" ] && ! command -v catt >/dev/null 2>&1; then
    if [ ! -x "$HOME/.local/bin/uv" ] && ! command -v uv >/dev/null 2>&1; then
        echo "==> Installing uv (Python tool manager)"
        curl -fsSL https://astral.sh/uv/install.sh -o "$TMP/uv-install.sh"
        sh "$TMP/uv-install.sh"
    fi
    echo "==> Installing catt (the Cast engine)"
    UV_BIN="$(command -v uv || echo "$HOME/.local/bin/uv")"
    "$UV_BIN" tool install catt
fi

echo "==> Launching Fling"
open "$APP"
echo ""
echo "Done — Fling is the cast icon in the menu bar."
echo "First run: approve the permission prompts, then click"
echo "'Set Up TV Power…' and type the code the TV shows."
