#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Fling.app"
IDENTITY="REDACTED-LOCAL-IDENTITY"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Fling" "$APP/Contents/MacOS/Fling"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Re-signing on every build invalidates the previous Automation grants, so the
# stable identity matters: with the same signature macOS keeps the consent.
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"

echo "built: $APP"
