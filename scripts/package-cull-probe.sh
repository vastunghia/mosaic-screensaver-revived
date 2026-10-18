#!/bin/bash
# Makes the archive that carries scripts/cull-probe.sh to another Mac: the
# universal app, signed, the script as run.sh, and a README for whoever runs
# it. Builds the app first.
#
# Usage:
#     ./scripts/package-cull-probe.sh    # writes .build/dist/mosaic-cull-probe.zip
#
# The results come back as cull-<user>-<Mac>.zip, from that Mac's Desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

./Hosts/App/build.sh release --universal

STAGE=".build/cull-probe/mosaic-cull-probe"
rm -rf "$(dirname "$STAGE")"
mkdir -p "$STAGE" .build/dist
ditto ".build/bundle/Mosaic Companion.app" "$STAGE/Mosaic Companion.app"
codesign --verify --deep --strict "$STAGE/Mosaic Companion.app"
cp scripts/cull-probe.sh "$STAGE/run.sh"
chmod 755 "$STAGE/run.sh"
cat > "$STAGE/README.txt" <<'TEXT'
Mosaic, leaving weak photos out: a test run for another Mac
==========================================================

1. Quit Mosaic Companion if it is open (menu Mosaic Companion > Quit).
2. In Terminal, run:

       bash ~/Downloads/mosaic-cull-probe/run.sh

   (or wherever this folder is). Add --with-previews to include small
   previews of the photos in the results; without it, only numbers and
   identifiers leave the Mac.
3. If macOS asks about Photos, answer Allow Full Access.
4. Wait for "done" (1 to 30 minutes), then send back the zip it names on
   the Desktop, cull-<user>-<Mac>.zip.

Nothing is downloaded from iCloud, and this profile's own Mosaic index and
settings are not touched. The working copy of the index is deleted at the end.
TEXT

rm -f .build/dist/mosaic-cull-probe.zip
ditto -c -k --keepParent "$STAGE" .build/dist/mosaic-cull-probe.zip
echo "==> .build/dist/mosaic-cull-probe.zip"
