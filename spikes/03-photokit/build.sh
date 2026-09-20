#!/bin/bash
# Builds the two sides of spike 3: the app that indexes the Photos library and the .saver
# that reads the result back from inside the sandbox.
set -euo pipefail
cd "$(dirname "$0")"

# Stable signing identity: see scripts/sign.sh and spike 3 § 5.
source ../../scripts/sign.sh

TARGET="$(uname -m)-apple-macos15.0"
BUILD="build"
APP="$BUILD/MosaicSpike3Indexer.app"
SAVER="$BUILD/ThumbGrid.saver"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$SAVER/Contents/MacOS"

echo "==> app (indexes via PhotoKit)"
xcrun swiftc -target "$TARGET" -O \
    -o "$APP/Contents/MacOS/MosaicSpike3Indexer" \
    Sources/Index.swift Sources/bench.swift Sources/main.swift \
    -framework AppKit -framework Photos -framework CoreImage

# NSPhotoLibraryUsageDescription is mandatory: without it the authorisation request
# produces no prompt at all and the process is killed.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MosaicSpike3Indexer</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike3.indexer</string>
    <key>CFBundleName</key><string>MosaicSpike3Indexer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Spike 3 of the Mosaic project: it reads your photos to build the index of average colours the mosaic uses.</string>
</dict>
</plist>
PLIST
sign_bundle "$APP"

echo "==> saver (reads back inside the sandbox)"
# swiftc drives the link, otherwise the global stored properties go to SIGSEGV (spike 1).
xcrun swiftc -target "$TARGET" -module-name ThumbGrid -emit-library -O \
    -o "$SAVER/Contents/MacOS/ThumbGrid" \
    Sources/Index.swift Sources/ThumbGridView.swift \
    -framework ScreenSaver -framework AppKit \
    -Xlinker -bundle -Xlinker -rpath -Xlinker /usr/lib/swift

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ThumbGrid</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike3.thumbgrid</string>
    <key>CFBundleName</key><string>ThumbGrid</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>ThumbGridView</string>
</dict>
</plist>
PLIST
sign_bundle "$SAVER"

DEST="$HOME/Library/Screen Savers"
mkdir -p "$DEST"
rm -rf "$DEST/ThumbGrid.saver"
cp -R "$SAVER" "$DEST/"
echo "==> app in $APP"
echo "==> saver installed in $DEST/ThumbGrid.saver"
