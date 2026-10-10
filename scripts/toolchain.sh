#!/bin/bash
# The tools a build needs beyond SwiftPM, checked before anything is compiled.
#
# The Metal compiler is not part of the Command Line Tools, and from Xcode 26 on
# it is not part of Xcode either: it is the Metal Toolchain, a component
# downloaded on its own. Xcode ships a `metal` that only forwards to it, so
# `xcrun -f metal` finds a compiler even when there is none; running it is the
# only reliable test.
#
# Usage:
#     source scripts/toolchain.sh
#     require_metal_toolchain

require_metal_toolchain() {
    if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
        return
    fi

    local developer
    developer="$(xcode-select -p 2>/dev/null || true)"
    echo "error: the Metal compiler is missing; the shaders cannot be built." >&2
    case "$developer" in
        *.app/Contents/Developer)
            echo "    Xcode is selected ($developer) but the Metal Toolchain is not installed:" >&2
            echo "        xcodebuild -downloadComponent MetalToolchain" >&2
            ;;
        *)
            if [ -d /Applications/Xcode.app ]; then
                echo "    The active developer directory is ${developer:-unset}, not Xcode. Select Xcode:" >&2
                echo "        sudo xcode-select -s /Applications/Xcode.app" >&2
            else
                echo "    Building Mosaic needs Xcode 26 or later, which is not installed." >&2
                echo "    Install it from the App Store, then:" >&2
                echo "        sudo xcode-select -s /Applications/Xcode.app" >&2
            fi
            echo "    and, if Xcode has not downloaded it yet, the Metal Toolchain:" >&2
            echo "        xcodebuild -downloadComponent MetalToolchain" >&2
            ;;
    esac
    exit 1
}
