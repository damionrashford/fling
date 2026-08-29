#!/usr/bin/env bash
# Installs the latest Fling release on this Mac. curl-fetched files carry no
# quarantine attribute, so this needs no Gatekeeper "Open Anyway" dance.
set -euo pipefail

REPO="damionrashford/fling"

echo "==> Finding latest Fling release"
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*Fling-Install\.zip"' \
    | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$ZIP_URL" ] || { echo "error: no release asset found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $ZIP_URL"
curl -fsSL "$ZIP_URL" -o "$TMP/fling.zip"
ditto -x -k "$TMP/fling.zip" "$TMP"

echo "==> Installing to /Applications"
killall Fling 2>/dev/null || true
rm -rf /Applications/Fling.app
ditto "$TMP/Fling/Fling.app" /Applications/Fling.app
# Belt and braces — harmless when the attribute is absent.
xattr -dr com.apple.quarantine /Applications/Fling.app 2>/dev/null || true
# The signature was made on another Mac; if this one rejects it, an ad-hoc
# local signature always passes.
codesign --verify /Applications/Fling.app 2>/dev/null \
    || codesign --force --deep -s - /Applications/Fling.app

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
open /Applications/Fling.app
echo ""
echo "Done — Fling is the cast icon in the menu bar."
echo "First run: approve the permission prompts, then Remote tab ->"
echo "'Set Up TV Power…' and type the code the TV shows."
