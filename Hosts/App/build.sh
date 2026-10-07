#!/bin/bash
# Builds Mosaic.app: the container app, which is also the development harness.
#
# Three things SwiftPM will not do on its own, and this is where they happen:
# compiling the Metal shaders (swift build has no rule for .metal), assembling
# the bundle, and signing it with a stable identity so TCC does not revoke the
# Photos grant on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/identity.sh
source scripts/sign.sh

CONFIG="${1:-release}"
BUILD=".build/bundle"
APP="$BUILD/$APP_NAME.app"
TARGET="$(uname -m)-apple-macos15.0"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product MosaicApp

echo "==> shaders"
mkdir -p "$BUILD"
xcrun -sdk macosx metal -c Sources/MosaicRender/Shaders.metal -o "$BUILD/Shaders.air"
xcrun -sdk macosx metallib "$BUILD/Shaders.air" -o "$BUILD/default.metallib"

# The app carries the screen saver and installs it (milestone 5): built and
# signed on its own first, then sealed into the app as a resource.
echo "==> screen saver"
./Hosts/Saver/build.sh "$CONFIG"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "$CONFIG" --show-bin-path)/MosaicApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD/default.metallib" "$APP/Contents/Resources/default.metallib"
cp -R "$BUILD/$SAVER_NAME.saver" "$APP/Contents/Resources/"

# The Info.plist of an app whose TCC identity has to stay stable is not a file
# to keep changing. LSUIElement keeps the app out of the Dock until it opens a
# window (launched at login it opens none); the URL scheme is how the .saver
# calls it (spike 4, MosaicURL).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$APP_BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>mosaic</string></array>
        </dict>
    </array>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Mosaic reads your photo library to build the screen saver's mosaics.</string>
</dict>
</plist>
PLIST

sign_bundle "$APP"

echo "==> check"
show_signature "$APP"
echo "==> $APP"
echo "    open with:  open \"$APP\""
echo "    full screen:  open \"$APP\" --args --full-screen"
