#!/usr/bin/env bash
# Builds a shareable zip: Fling.app + a double-clickable installer that gets a
# non-notarized app running on someone else's Mac (no Developer Program).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/bundle.sh"

DIST="$ROOT/build/dist/Fling"
rm -rf "$ROOT/build/dist"
mkdir -p "$DIST"
ditto "$ROOT/build/Fling.app" "$DIST/Fling.app"

cat > "$DIST/Install Fling.command" <<'INSTALLER'
#!/bin/bash
# Installs Fling on this Mac. The app is signed but not notarized (no paid
# Apple Developer account), so this script does what Gatekeeper's "Open
# Anyway" button would: clears the quarantine flag on a file you chose to
# trust. It also installs the Cast engine Fling drives.
set -uo pipefail
cd "$(dirname "$0")"

echo "==> Installing Fling.app to /Applications"
rm -rf /Applications/Fling.app
ditto Fling.app /Applications/Fling.app
xattr -dr com.apple.quarantine /Applications/Fling.app 2>/dev/null

# The signing cert came from another Mac; if this machine rejects it, fall
# back to a local ad-hoc signature, which macOS always accepts.
if ! codesign --verify /Applications/Fling.app 2>/dev/null; then
    echo "==> Re-signing locally"
    codesign --force --deep -s - /Applications/Fling.app
fi

if [ ! -x "$HOME/.local/bin/catt" ] && ! command -v catt >/dev/null 2>&1; then
    if [ ! -x "$HOME/.local/bin/uv" ] && ! command -v uv >/dev/null 2>&1; then
        echo "==> Installing uv (Python tool manager)"
        UV_INSTALLER="$(mktemp)"
        curl -LsSf https://astral.sh/uv/install.sh -o "$UV_INSTALLER"
        sh "$UV_INSTALLER"
        rm -f "$UV_INSTALLER"
    fi
    echo "==> Installing catt (the Cast engine)"
    UV_BIN="$(command -v uv || echo "$HOME/.local/bin/uv")"
    "$UV_BIN" tool install catt
fi

echo "==> Launching Fling"
open /Applications/Fling.app
echo ""
echo "Done. Fling lives in the menu bar (the cast icon, top right)."
echo "First run: allow the browser-access prompts, then open the Remote tab"
echo "and click 'Set Up TV Power…' — the TV will show a 6-character code."
INSTALLER
chmod +x "$DIST/Install Fling.command"

cat > "$DIST/README.txt" <<'README'
Fling — menu bar remote + caster for the living room TV

1. Right-click "Install Fling.command" -> Open -> Open.
   (Plain double-click is blocked because this ships outside the App Store.
   You only do this once.)
2. The installer puts Fling in /Applications, sets up the Cast engine,
   and launches it.
3. Requirements: same Wi-Fi as the TV.
4. First run: approve the permission prompts, then Remote tab ->
   "Set Up TV Power…" and type the code the TV shows.
README

ditto -c -k --sequesterRsrc --keepParent "$DIST" "$ROOT/build/Fling-Install.zip"
echo "packaged: $ROOT/build/Fling-Install.zip"
