#!/bin/bash
# Leaving weak photos out, measured on any Mac and profile: builds an index of
# this profile's photographs from scratch without culling, then with it, then
# again, writes the culling pages, and measures Vision on the images indexing
# has. The results go in one zip on the Desktop.
#
# Usage:
#     ./scripts/cull-probe.sh                   numbers and identifiers only
#     ./scripts/cull-probe.sh --with-previews   also pages with small previews
#
# It runs the Mosaic Companion.app beside it, as in the archive that
# scripts/package-cull-probe.sh makes to carry to another Mac (where it is
# run.sh), or else the one ./Hosts/App/build.sh left in .build/bundle.
#
# This profile's own Mosaic index and preferences are left alone, and nothing is
# downloaded from iCloud. The working index, with its thumbnails, is deleted at
# the end. It takes 1 to 30 minutes depending on the Mac and the library.
set -u
cd "$(dirname "$0")"
APP="$(pwd)/Mosaic Companion.app"
[ -d "$APP" ] || APP="$(cd .. && pwd)/.build/bundle/Mosaic Companion.app"
if [ ! -d "$APP" ]; then
    echo "No Mosaic Companion.app beside this script, nor in .build/bundle: run ./Hosts/App/build.sh first."
    exit 1
fi
PREVIEWS=0
[ "${1:-}" = "--with-previews" ] && PREVIEWS=1

NAME="cull-$(id -un)-$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
OUT="$HOME/Desktop/$NAME"
WORK="$HOME/Library/Caches/mosaic-cull-probe"

if pgrep -u "$(id -u)" -x "Mosaic Companion" >/dev/null; then
    echo "Quit Mosaic Companion first (menu Mosaic Companion > Quit), then run this again."
    exit 1
fi

# Copied over AirDrop or a disk, the app is quarantined and Gatekeeper would stop it.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"
START="$(date '+%Y-%m-%d %H:%M:%S')"

SEED=$(defaults read com.vastunghia.Mosaic subsetSeed 2>/dev/null)
RULE=$(defaults read com.vastunghia.Mosaic subsetRule 2>/dev/null || echo uniformInTime)
SIZE=$(defaults read com.vastunghia.Mosaic subsetSize 2>/dev/null || echo 2048)
SEEDNOTE="from this profile's preferences"
if [ -z "$SEED" ]; then SEED=1; SEEDNOTE="none in the preferences: Mosaic Companion never set up here"; fi
{
    echo "user $(id -un), $START"
    sw_vers
    echo "arch $(uname -m)"
    sysctl -n hw.model machdep.cpu.brand_string hw.ncpu 2>/dev/null
    echo "rule $RULE, size $SIZE, seed $SEED ($SEEDNOTE)"
    echo "albums: $(defaults read com.vastunghia.Mosaic albums 2>/dev/null | tr -d '\n ')"
    echo "downloads: $(defaults read com.vastunghia.Mosaic iCloudDownloads 2>/dev/null)"
    echo "--- com.apple.photos.shareddefaults"
    defaults read com.apple.photos.shareddefaults 2>&1 | grep -E "downloadAndKeepOriginals|CPLDefaultDownload|cloudPhotosPaused|DiskSpaceWasLow"
    echo "--- app"
    /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" -c "Print CFBundleVersion" "$APP/Contents/Info.plist"
} > "$OUT/context.txt"
COMMON=(--photos-library --subset "$RULE" --subset-size "$SIZE" --subset-seed "$SEED")

run() {
    local name=$1; shift
    echo "$(date +%T) ${name} ..."
    local start=$(date +%s)
    open -W --stdout "$OUT/${name}.txt" --stderr "$OUT/${name}.err" "$APP" --args "${COMMON[@]}" "$@"
    # open -W can return at once if LaunchServices is still registering the app.
    while pgrep -u "$(id -u)" -f "$APP/Contents/MacOS" >/dev/null; do sleep 2; done
    echo "${name}: $(( $(date +%s) - start )) s" | tee -a "$OUT/times.txt"
    sleep 2
}

echo "If macOS asks about Photos, answer Allow Full Access."
run build-off --index-only --index "$WORK/idx-off" --cull off
run build-on --index-only --index "$WORK/idx-on" --cull on
run build-on-2 --index-only --index "$WORK/idx-on" --cull on
run specimen --index "$WORK/idx-on" --export-culling "$OUT/specimen"
run probe-quality --probe-quality 2048 --probe-csv "$OUT/probe-quality.csv"

# What the index remembers, without the thumbnails.
cp "$WORK/idx-off/manifest.json" "$OUT/manifest-off.json" 2>/dev/null
cp "$WORK/idx-on/manifest.json" "$OUT/manifest-on.json" 2>/dev/null
/usr/bin/log show --predicate 'subsystem == "com.vastunghia.Mosaic"' --start "$START" --style compact \
    > "$OUT/log.txt" 2>&1
if [ "$PREVIEWS" -eq 0 ]; then
    rm -rf "$OUT/specimen/previews" "$OUT/specimen/index.html" "$OUT/specimen/utility.html"
fi
rm -rf "$WORK"

cd "$HOME/Desktop" && ditto -c -k --keepParent "$NAME" "$NAME.zip"
echo "$(date +%T) done: send $HOME/Desktop/$NAME.zip back to Sergio"
