#!/bin/bash
# Builds Mosaic.saver and, with --install, puts it in ~/Library/Screen Savers.
#
# SwiftPM builds the executable as a dynamic library, linked by the Swift
# driver: a bundle linked by clang loads but crashes on its first Swift global
# (spike 1). This script compiles the shaders, which `swift build` ignores, and
# assembles and signs the bundle.
set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/identity.sh
source scripts/sign.sh

CONFIG="release"
INSTALL=0
ARCHS=()
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
        debug|release) CONFIG="$argument" ;;
        *) echo "usage: $0 [debug|release] [--universal] [--install]" >&2; exit 2 ;;
    esac
done

BUILD=".build/bundle"
SAVER="$BUILD/$SAVER_NAME.saver"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product MosaicSaver

echo "==> shaders"
mkdir -p "$BUILD"
xcrun -sdk macosx metal -c Sources/MosaicRender/Shaders.metal -o "$BUILD/Shaders.air"
xcrun -sdk macosx metallib "$BUILD/Shaders.air" -o "$BUILD/default.metallib"

# The thumbnail the Screen Saver settings show, drawn by the icon's script and
# only again when it changes.
THUMBNAILS="$BUILD/thumbnails"
if [ ! -f "$THUMBNAILS/thumbnail@2x.png" ] || [ scripts/make-icon.swift -nt "$THUMBNAILS/thumbnail@2x.png" ]; then
    echo "==> thumbnail"
    swift scripts/make-icon.swift --thumbnail "$THUMBNAILS"
fi

echo "==> bundle"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp "$THUMBNAILS/thumbnail.png" "$THUMBNAILS/thumbnail@2x.png" "$SAVER/Contents/Resources/"
cp "$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/libMosaicSaver.dylib" "$SAVER/Contents/MacOS/$SAVER_NAME"
cp "$BUILD/default.metallib" "$SAVER/Contents/Resources/default.metallib"

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$SAVER_NAME</string>
    <key>CFBundleIdentifier</key><string>$SAVER_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$SAVER_NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>MosaicSaverView</string>
</dict>
</plist>
PLIST

sign_bundle "$SAVER"

echo "==> check"
file "$SAVER/Contents/MacOS/$SAVER_NAME"
show_signature "$SAVER"
echo "==> $SAVER"

if [ "$INSTALL" = 1 ]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/$SAVER_NAME.saver"
    cp -R "$SAVER" "$DEST/"
    echo "==> installed in $DEST/$SAVER_NAME.saver"
    echo "    legacyScreenSaver keeps a loaded saver until it exits; after reinstalling:"
    echo "    killall legacyScreenSaver 2>/dev/null"
fi
