#!/bin/bash
# Build and launch Bandwatch as a proper .app bundle.
#
# Prefer this over `swift run Bandwatch` for anything involving the UI: `swift
# run` launches the UNBUNDLED binary (.build/debug/Bandwatch), which has no
# bundle identifier or Info.plist. For a MenuBarExtra-based app that means the
# main window's `.defaultLaunchBehavior(.presented)` (macOS 15) does not
# reliably present a window, and window-state/preferences restoration is
# unstable. The bundle presents the window every time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-app.sh" "${1:-debug}"
open "$ROOT/build/Bandwatch.app"
