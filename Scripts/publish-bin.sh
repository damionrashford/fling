#!/usr/bin/env bash
# Refreshes bin/Fling — the universal, ad-hoc-signed binary the repo installer
# serves. Run before pushing a release-worthy change, then commit bin/Fling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
mkdir -p "$ROOT/bin"
cp "$ROOT/.build/apple/Products/Release/Fling" "$ROOT/bin/Fling"
# Ad-hoc: strips any personal signing identity before the binary enters git.
codesign --force -s - "$ROOT/bin/Fling"
echo "refreshed: $ROOT/bin/Fling"
