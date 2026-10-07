#!/bin/bash
# Builds a release: the universal app, with the screen saver inside it, on a
# disk image to drag into Applications, and its checksum.
#
# It publishes nothing. The disk image and the command that would publish it
# are printed at the end.
#
# Usage:
#     ./scripts/release.sh               # from a clean, committed tree
#     ./scripts/release.sh --allow-dirty # a trial, never to be published
#
# The app is signed with the Apple Development identity, not Developer ID,
# and is not notarized: Gatekeeper refuses it on first launch, and the README
# says how to let it through. What the identity does buy is a designated
# requirement that stays the same from one release to the next, so an update
# keeps the Photos grant.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/identity.sh

ALLOW_DIRTY=0
for argument in "$@"; do
    case "$argument" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        *) echo "usage: $0 [--allow-dirty]" >&2; exit 2 ;;
    esac
done

if [ -n "$(git status --porcelain)" ]; then
    if [ "$ALLOW_DIRTY" = 1 ]; then
        echo "==> WARNING: uncommitted changes; this build is not a release" >&2
    else
        echo "error: uncommitted changes. Commit them, or pass --allow-dirty for a trial." >&2
        exit 1
    fi
fi

./Hosts/App/build.sh release --universal

APP=".build/bundle/$APP_NAME.app"
SAVER="$APP/Contents/Resources/$SAVER_NAME.saver"
# Not .build/release, which is SwiftPM's own build products.
OUT=".build/dist"
NAME="$APP_NAME-$VERSION"
DMG="$OUT/$NAME.dmg"

echo "==> verify"
codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/$APP_NAME" "$SAVER/Contents/MacOS/$SAVER_NAME"; do
    archs="$(lipo -archs "$binary")"
    if [[ "$archs" != *x86_64* || "$archs" != *arm64* ]]; then
        echo "error: $binary is $archs, not universal" >&2
        exit 1
    fi
done
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: ad-hoc signature: every release would be a new app to TCC" >&2
    exit 1
fi

echo "==> disk image"
STAGING="$(mktemp -d)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$SCRATCH"' EXIT
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# Read-write first, so the Finder can lay the window out, then compressed.
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW "$SCRATCH/rw.dmg"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$SCRATCH/rw.dmg" \
    | sed -n 's|^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*||p')"

# The layout is stored by the Finder in the volume's .DS_Store. Doing it asks
# once for permission to control the Finder; refused, the disk image works
# all the same, with the Finder's own layout.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 740, 460}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set position of item "$APP_NAME.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "==> WARNING: the Finder did not lay the window out; the disk image is plain" >&2
fi
# Left by the system on any volume mounted read-write.
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach -quiet "$MOUNT"

mkdir -p "$OUT"
rm -f "$DMG"
hdiutil convert -quiet "$SCRATCH/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

echo "==> $DMG"
du -h "$DMG" | cut -f1
cat "$OUT/$NAME.dmg.sha256"
echo "    to publish, once the tag is pushed:"
echo "    gh release create v$VERSION \"$DMG\" \"$OUT/$NAME.dmg.sha256\" --title \"$APP_NAME $VERSION\""
