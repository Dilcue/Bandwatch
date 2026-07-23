#!/bin/bash
# Activates the swiftly-managed Swift 6.3.3 toolchain.
#
# Required: Command Line Tools ships Swift 6.2.3, which has no Testing module.
# swiftly only writes to ~/.zprofile, which non-interactive shells do not read,
# so `swift` would otherwise silently resolve to the wrong toolchain.
#
# Usage:  . scripts/env.sh && swift test
if [ -f "$HOME/.swiftly/env.sh" ]; then
    . "$HOME/.swiftly/env.sh"
else
    echo "ERROR: swiftly not found at ~/.swiftly/env.sh" >&2
    return 1 2>/dev/null || exit 1
fi
