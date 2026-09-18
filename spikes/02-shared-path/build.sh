#!/bin/bash
# Builds the two sides of spike 2: the app that writes and the .saver that reads back.
set -euo pipefail
cd "$(dirname "$0")"

TARGET="$(uname -m)-apple-macos15.0"
BUILD="build"
APP="$BUILD/MosaicSpike2Writer.app"
SAVER="$BUILD/PathProbe.saver"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$SAVER/Contents/MacOS"

echo "==> app (the writing side)"
# It has to be a real, signed .app: launched with `open` it has a TCC identity of its own,
# whereas run from a shell it would inherit the Terminal's and falsify the result.
xcrun swiftc -target "$TARGET" -O \
    -o "$APP/Contents/MacOS/MosaicSpike2Writer" \
    Sources/Probe.swift Sources/main.swift \
    -framework AppKit

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MosaicSpike2Writer</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike2.writer</string>
    <key>CFBundleName</key><string>MosaicSpike2Writer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"

echo "==> saver (the reading side)"
# swiftc drives the link: with clang -bundle the global stored properties go to SIGSEGV (spike 1).
xcrun swiftc -target "$TARGET" -module-name PathProbe -emit-library -O \
    -o "$SAVER/Contents/MacOS/PathProbe" \
    Sources/Probe.swift Sources/PathProbeView.swift \
    -framework ScreenSaver -framework AppKit \
    -Xlinker -bundle -Xlinker -rpath -Xlinker /usr/lib/swift

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PathProbe</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike2.pathprobe</string>
    <key>CFBundleName</key><string>PathProbe</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>PathProbeView</string>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$SAVER"

DEST="$HOME/Library/Screen Savers"
mkdir -p "$DEST"
rm -rf "$DEST/PathProbe.saver"
cp -R "$SAVER" "$DEST/"
echo "==> app in $APP"
echo "==> saver installed in $DEST/PathProbe.saver"
