#!/bin/bash
# Builds Mosaic Companion.app: the app that carries and prepares the screen
# saver, which is also the development harness.
#
# Four things SwiftPM will not do on its own, and this is where they happen:
# compiling the Metal shaders (swift build has no rule for .metal), compiling
# the String Catalogs into the bundle's .lproj folders, assembling the bundle,
# and signing it with a stable identity so TCC does not revoke the Photos grant
# on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/identity.sh
source scripts/sign.sh
source scripts/strings.sh
source scripts/toolchain.sh

CONFIG="release"
ARCHS=()
UNIVERSAL=()
INSTALL=0
for argument in "$@"; do
    case "$argument" in
        --universal) ARCHS=(--arch arm64 --arch x86_64); UNIVERSAL=(--universal) ;;
        --install) INSTALL=1 ;;
        debug|release) CONFIG="$argument" ;;
        *) echo "usage: $0 [debug|release] [--universal] [--install]" >&2; exit 2 ;;
    esac
done
BUILD=".build/bundle"
APP="$BUILD/$APP_NAME.app"

require_metal_toolchain

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product MosaicApp

echo "==> shaders"
mkdir -p "$BUILD"
xcrun -sdk macosx metal -c Sources/MosaicRender/Shaders.metal -o "$BUILD/Shaders.air"
xcrun -sdk macosx metallib "$BUILD/Shaders.air" -o "$BUILD/default.metallib"

# The app carries the screen saver and installs it (milestone 5): built and
# signed on its own first, then sealed into the app as a resource.
echo "==> screen saver"
./Hosts/Saver/build.sh "$CONFIG" ${UNIVERSAL[@]+"${UNIVERSAL[@]}"}

# The icon is drawn by a script, and only again when the script changes:
# compiling it takes a few seconds.
ICON="$BUILD/AppIcon.icns"
if [ ! -f "$ICON" ] || [ scripts/make-icon.swift -nt "$ICON" ]; then
    echo "==> icon"
    swift scripts/make-icon.swift "$ICON"
fi

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/MosaicApp" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD/default.metallib" "$APP/Contents/Resources/default.metallib"
cp -R "$BUILD/$SAVER_NAME.saver" "$APP/Contents/Resources/"

echo "==> strings"
compile_strings Hosts/App/Localizable.xcstrings "$APP/Contents/Resources"
compile_strings Hosts/App/InfoPlist.xcstrings "$APP/Contents/Resources"
PHOTOS_USAGE="$(info_plist_string Hosts/App/InfoPlist.xcstrings NSPhotoLibraryUsageDescription)"

# The user guide travels in the bundle, so it always describes this build:
# an Apple Help Book, opened from the Help menu, which searches it.
echo "==> help book"
HELP="$APP/Contents/Resources/$APP_NAME.help"
mkdir -p "$HELP/Contents/Resources/en.lproj"
cp Hosts/App/Help/*.html Hosts/App/Help/*.css "$HELP/Contents/Resources/en.lproj/"
hiutil -I corespotlight -Caf "$HELP/Contents/Resources/en.lproj/$APP_NAME.cshelpindex" -s en \
    "$HELP/Contents/Resources/en.lproj"
HELP_BOOK="$APP_BUNDLE_ID.help"
cat > "$HELP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>$HELP_BOOK</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>HPDBookAccessPath</key><string>index.html</string>
    <key>HPDBookIndexPath</key><string>$APP_NAME.cshelpindex</string>
    <key>HPDBookTitle</key><string>$PRODUCT_NAME Help</string>
    <key>HPDBookType</key><string>3</string>
</dict>
</plist>
PLIST

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
    <key>CFBundleHelpBookFolder</key><string>$APP_NAME.help</string>
    <key>CFBundleHelpBookName</key><string>$HELP_BOOK</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
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
    <string>$PHOTOS_USAGE</string>
</dict>
</plist>
PLIST

sign_bundle "$APP"

echo "==> check"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
show_signature "$APP"
echo "==> $APP"

# The copy in /Applications is the one LaunchServices opens for mosaic://
# and the one a login item should point at, so that is where a build goes to
# be used rather than tried.
if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    # A signal, not a quit event: a login item asks before quitting, and a
    # build has nobody to answer. Indexing resumes from its checkpoints.
    if pgrep -xq "$APP_NAME"; then
        pkill -TERM -x "$APP_NAME" || true
        for _ in $(seq 50); do pgrep -xq "$APP_NAME" || break; sleep 0.1; done
    fi
    # A standard user cannot write to /Applications, nor sudo: macOS's own
    # dialog asks for an administrator's name and password instead.
    if [ -w /Applications ] && { [ ! -e "$DEST" ] || [ -w "$DEST" ]; }; then
        rm -rf "$DEST"
        ditto "$APP" "$DEST"
    else
        echo "==> /Applications is not writable by $(id -un): asking for an administrator"
        if ! osascript - "$PWD/$APP" "$DEST" >/dev/null <<'APPLESCRIPT'
on run argv
    set source to quoted form of item 1 of argv
    set destination to quoted form of item 2 of argv
    do shell script "/bin/rm -rf " & destination & " && /usr/bin/ditto " & source & " " & destination with administrator privileges
end run
APPLESCRIPT
        then
            echo "error: not installed; the build is still in $APP" >&2
            exit 1
        fi
    fi
    APP="$DEST"
    echo "==> installed in $DEST; the app updates the screen saver from its window"
fi
echo "    open with:  open \"$APP\""
echo "    full screen:  open \"$APP\" --args --full-screen"
