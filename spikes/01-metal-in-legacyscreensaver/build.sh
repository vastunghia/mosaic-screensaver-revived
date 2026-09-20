#!/bin/bash
# Builds MetalSpike.saver and installs it into ~/Library/Screen Savers/.
# No Xcode project: for a spike the command-line toolchain is enough, and it reads well.
set -euo pipefail

cd "$(dirname "$0")"

# Stable signing identity: see scripts/sign.sh and spike 3 § 5.
source ../../scripts/sign.sh

NAME="MetalSpike"
BUNDLE_ID="dev.mosaic.spike.metalspike"
TARGET="$(uname -m)-apple-macos15.0"
BUILD="build"
SAVER="$BUILD/$NAME.saver"

rm -rf "$BUILD"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

echo "==> shaders"
xcrun -sdk macosx metal -c Sources/Shaders.metal -o "$BUILD/Shaders.air"
xcrun -sdk macosx metallib "$BUILD/Shaders.air" -o "$SAVER/Contents/Resources/default.metallib"

echo "==> swift + link (swiftc drives the link: needed for the Swift runtime, see README)"
xcrun swiftc \
    -target "$TARGET" \
    -module-name "$NAME" \
    -emit-library \
    -O \
    -o "$SAVER/Contents/MacOS/$NAME" \
    Sources/MetalSpikeView.swift \
    -framework ScreenSaver \
    -framework Metal \
    -framework QuartzCore \
    -framework AppKit \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker /usr/lib/swift

echo "==> Info.plist"
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>MetalSpikeView</string>
</dict>
</plist>
PLIST

sign_bundle "$SAVER"

echo "==> check"
file "$SAVER/Contents/MacOS/$NAME"
codesign -dv "$SAVER" 2>&1 | head -4

DEST="$HOME/Library/Screen Savers"
mkdir -p "$DEST"
rm -rf "$DEST/$NAME.saver"
cp -R "$SAVER" "$DEST/"
echo "==> installed in $DEST/$NAME.saver"
