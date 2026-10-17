#!/bin/bash
# Runs spike 5 on another Mac and leaves the results in one zip on the Desktop.
# Only identifiers and numbers leave the Mac: no photographs, no previews.
#
#   bash run.sh
set -uo pipefail
cd "$(dirname "$0")"

NAME="spike5-$(whoami)-$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
OUT="$HOME/Desktop/$NAME"
mkdir -p "$OUT"

# Copied over AirDrop or a disk, the app is quarantined and Gatekeeper would stop it.
xattr -dr com.apple.quarantine Spike5Probe.app 2>/dev/null

{
    date
    sw_vers
    echo "arch $(uname -m)"
    sysctl -n hw.model machdep.cpu.brand_string 2>/dev/null
    echo "user $(whoami)"
    echo "--- com.apple.photos.shareddefaults"
    defaults read com.apple.photos.shareddefaults 2>&1 | grep -E "downloadAndKeepOriginals|CPLDefaultDownload|cloudPhotosPaused|DiskSpaceWasLow"
} > "$OUT/system.txt"

echo "==> 1 of 2: reading the Photos database (answer 'Allow Full Access' if asked)"
open -W --stdout "$OUT/match.txt" --stderr "$OUT/match.err" Spike5Probe.app \
    --args --request --match --dump "$OUT/assets.csv"
cat "$OUT/match.txt"

echo "==> 2 of 2: Vision on 1024 photos from the library (a few minutes)"
open -W --stdout "$OUT/vision-run.txt" --stderr "$OUT/vision-run.err" Spike5Probe.app \
    --args --vision "$OUT" --sample 1024 --sizes 854,427 --no-previews
tail -4 "$OUT/vision-run.txt"

cd "$HOME/Desktop" && ditto -c -k --keepParent "$NAME" "$NAME.zip"
echo "==> done: send $HOME/Desktop/$NAME.zip back to Sergio's iMac"
