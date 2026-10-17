#!/bin/bash
# Builds the spike 5 probe as a signed app with its own bundle identifier, so its
# TCC grants start empty and stay apart from Mosaic Companion's and Terminal's.
set -euo pipefail
cd "$(dirname "$0")"

source ../../scripts/sign.sh

# Universal and from macOS 14, so the same bundle runs on the other Macs of the
# household. Vision's aesthetics request needs 15 and is skipped below it.
ARCHS=(x86_64 arm64)
BUILD="build"
APP="$BUILD/Spike5Probe.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"

echo "==> probe app"
SLICES=()
for arch in "${ARCHS[@]}"; do
    xcrun swiftc -target "$arch-apple-macos14.0" -O -o "$BUILD/Spike5Probe-$arch" \
        Sources/main.swift Sources/Match.swift Sources/VisionScores.swift \
        -framework Photos -framework Vision -framework AppKit -lsqlite3
    SLICES+=("$BUILD/Spike5Probe-$arch")
done
lipo -create -output "$APP/Contents/MacOS/Spike5Probe" "${SLICES[@]}"
rm "${SLICES[@]}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Spike5Probe</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike5.probe</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Spike5Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Spike 5 checks which Photos databases an app with this permission can read.</string>
</dict>
</plist>
PLIST
sign_bundle "$APP"
echo "built $APP"
