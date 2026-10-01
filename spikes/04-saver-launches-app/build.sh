#!/bin/bash
# Builds the three pieces of spike 4: the probe app, the saver that launches it, and
# the control host that loads the saver outside the sandbox. Installs the saver into
# ~/Library/Screen Savers/ and the probe into ~/Applications/, where LaunchServices
# finds it.
set -euo pipefail
cd "$(dirname "$0")"

# Stable signing identity, so the probe keeps its Photos grant across builds.
source ../../scripts/sign.sh

TARGET="$(uname -m)-apple-macos15.0"
BUILD="build"
APP="$BUILD/Spike4Probe.app"
SAVER="$BUILD/Spike4Launcher.saver"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$SAVER/Contents/MacOS"

echo "==> probe app"
xcrun swiftc -target "$TARGET" -O -o "$APP/Contents/MacOS/Spike4Probe" Sources/Probe.swift \
    -framework AppKit -framework Photos -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Spike4Probe</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike4.probe</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Spike4Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>dev.mosaic.spike4.probe</string>
        <key>CFBundleURLSchemes</key><array><string>spike4probe</string></array>
    </dict></array>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Spike 4 checks whether a launched app keeps its Photos access.</string>
</dict>
</plist>
PLIST
sign_bundle "$APP"

echo "==> saver (swiftc drives the link, see spike 1)"
xcrun swiftc -target "$TARGET" -module-name Spike4Launcher -emit-library -O \
    -o "$SAVER/Contents/MacOS/Spike4Launcher" Sources/LauncherView.swift \
    -framework ScreenSaver -framework AppKit \
    -Xlinker -bundle -Xlinker -rpath -Xlinker /usr/lib/swift
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Spike4Launcher</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike4.launcher</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Spike4Launcher</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>LauncherView</string>
</dict>
</plist>
PLIST
sign_bundle "$SAVER"

echo "==> control host"
xcrun swiftc -target "$TARGET" -O -o "$BUILD/host" Sources/host.swift -framework AppKit -framework ScreenSaver

mkdir -p "$HOME/Applications" "$HOME/Library/Screen Savers"
rm -rf "$HOME/Applications/Spike4Probe.app" "$HOME/Library/Screen Savers/Spike4Launcher.saver"
cp -R "$APP" "$HOME/Applications/"
cp -R "$SAVER" "$HOME/Library/Screen Savers/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$HOME/Applications/Spike4Probe.app"
echo "==> installed ~/Applications/Spike4Probe.app and ~/Library/Screen Savers/Spike4Launcher.saver"
