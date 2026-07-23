#!/bin/bash
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Bandwatch.app"

echo "==> Building ($CONFIG)"
. "$HOME/.swiftly/env.sh"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/Bandwatch"
if [ ! -f "$BIN" ]; then
    echo "ERROR: binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bandwatch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/Bandwatch.icns" ]; then
    cp "$ROOT/Resources/Bandwatch.icns" "$APP/Contents/Resources/Bandwatch.icns"
fi

echo "==> Ad-hoc signing"
# TCC binds microphone permission to bundle ID + signature. Ad-hoc signing gives
# a stable enough identity that permission persists across rebuilds.
codesign --force --sign - --timestamp=none "$APP"

echo "==> Verifying"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
echo "    Run with: open \"$APP\""
