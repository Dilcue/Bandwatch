#!/bin/bash
# Builds a UNIVERSAL (arm64 + x86_64) release Bandwatch.app and packages it as a
# distributable zip for deploying to another Mac.
#
# The app is ad-hoc signed (no paid Apple Developer account), so Gatekeeper on
# the receiving Mac will block it until quarantine is stripped — see the printed
# instructions at the end and DEPLOY.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Bandwatch.app"

# Use the swiftly-managed toolchain locally; on CI (no swiftly) fall back to the
# runner's Swift, which the swift-tools-version 6.0 package builds fine with.
if [ -f "$HOME/.swiftly/env.sh" ]; then . "$HOME/.swiftly/env.sh"; fi
BINPATH="$(swift build -c release --show-bin-path)"

echo "==> Building arm64 (native)"
swift build -c release >/dev/null
cp "$BINPATH/Bandwatch" /tmp/bw-arm64

echo "==> Building x86_64 (cross)"
swift build -c release -Xswiftc -target -Xswiftc x86_64-apple-macos15 >/dev/null
cp "$BINPATH/Bandwatch" /tmp/bw-x86

echo "==> Fusing universal binary"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create /tmp/bw-arm64 /tmp/bw-x86 -output "$APP/Contents/MacOS/Bandwatch"
lipo -archs "$APP/Contents/MacOS/Bandwatch" | sed 's/^/    archs: /'

echo "==> Assembling bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/Bandwatch.icns" ] && cp "$ROOT/Resources/Bandwatch.icns" "$APP/Contents/Resources/Bandwatch.icns"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "==> Zipping (ditto preserves the bundle correctly)"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ZIP="$DIST/Bandwatch-$VERSION-universal.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "==> Built $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo
echo "    To deploy to another Mac (macOS 15+):"
echo "      1. Copy the zip over and unzip it."
echo "      2. Strip the Gatekeeper quarantine (ad-hoc signed, not notarized):"
echo "           xattr -dr com.apple.quarantine /path/to/Bandwatch.app"
echo "      3. Open it, grant microphone access when asked."
echo "    See DEPLOY.md for the full walkthrough."
