#!/bin/bash
# Builds LocaleProbe.saver with a String Catalog compiled by xcstringstool, installs it into
# ~/Library/Screen Savers/, and builds the command-line control beside it.
#   ./build.sh                       # Info.plist declares CFBundleLocalizations (en, it)
#   NO_LOCALIZATIONS_KEY=1 ./build.sh   # the same bundle without that key
set -euo pipefail

cd "$(dirname "$0")"
source ../../scripts/sign.sh

NAME="LocaleProbe"
BUNDLE_ID="dev.mosaic.spike.localeprobe"
TARGET="$(uname -m)-apple-macos15.0"
BUILD="build"
SAVER="$BUILD/$NAME.saver"

rm -rf "$BUILD"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

echo "==> strings"
xcrun xcstringstool compile Localizable.xcstrings --output-directory "$SAVER/Contents/Resources"
find "$SAVER/Contents/Resources" -type f | sort

echo "==> saver"
xcrun swiftc \
    -target "$TARGET" \
    -module-name "$NAME" \
    -emit-library \
    -O \
    -o "$SAVER/Contents/MacOS/$NAME" \
    Sources/Probe.swift Sources/LocaleProbeView.swift \
    -framework ScreenSaver \
    -framework AppKit \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker /usr/lib/swift

if [ -n "${NO_LOCALIZATIONS_KEY:-}" ]; then
    LOCALIZATIONS=""
else
    LOCALIZATIONS="<key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>"
fi

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    $LOCALIZATIONS
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>LocaleProbeView</string>
</dict>
</plist>
PLIST

sign_bundle "$SAVER"

echo "==> control"
xcrun swiftc -target "$TARGET" -O -o "$BUILD/locale-control" Sources/Probe.swift Sources/main.swift

# The same control wrapped in an app with only en.lproj, like legacyScreenSaver, once as is
# and once with CFBundleAllowMixedLocalizations. Run with
#   open -W --stdout out.txt build/LocaleHost.app --args "$PWD/build/LocaleProbe.saver"
for HOST in LocaleHost LocaleHostMixed; do
    APP="$BUILD/$HOST.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj"
    cp "$BUILD/locale-control" "$APP/Contents/MacOS/$HOST"
    printf '"x" = "x";\n' > "$APP/Contents/Resources/en.lproj/Localizable.strings"
    if [ "$HOST" = LocaleHostMixed ]; then
        MIXED="<key>CFBundleAllowMixedLocalizations</key><true/>"
    else
        MIXED=""
    fi
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$HOST</string>
    <key>CFBundleIdentifier</key><string>dev.mosaic.spike.$(echo $HOST | tr A-Z a-z)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    $MIXED
</dict>
</plist>
PLIST
    codesign --sign - --force "$APP" 2>/dev/null
done

DEST="$HOME/Library/Screen Savers"
rm -rf "$DEST/$NAME.saver"
cp -R "$SAVER" "$DEST/"
echo "==> installed in $DEST/$NAME.saver"
