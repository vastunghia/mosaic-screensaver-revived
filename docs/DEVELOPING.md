# Developing Mosaic

## The pieces

- **The effect** lives in libraries that know nothing about who hosts them: no
  `NSApplication`, no PhotoKit, no disk at frame time (`Sources/`). `MosaicEngine` is the
  entry point: give it a device, the photographs and a planner, and call
  `advance(to:)` once a frame.
- **The app** (`Hosts/App`) chooses the photographs, builds the index the screen saver
  reads, installs the saver, and is also the development harness: launched with any
  `--flag`, it runs the harness instead of its window.
- **The screen saver** (`Hosts/Saver`) is a thin shell around the engine inside
  `legacyScreenSaver`. It reads the index the app built and nothing else: a `.saver` runs
  in the system's sandbox, with no access to Photos.

## Building

```sh
./Hosts/App/build.sh                  # ".build/bundle/Mosaic Companion.app", this Mac's architecture
./Hosts/App/build.sh --universal      # arm64 and x86_64
./Hosts/App/build.sh --install        # and copy it to /Applications
./Hosts/Saver/build.sh --install      # the screen saver alone, into ~/Library/Screen Savers
./scripts/release.sh                  # universal, verified, on a disk image in .build/dist
swift test
```

The version is in `VERSION`; the build number is the commit count. The icon and the
Screen Saver settings' thumbnail are drawn by `scripts/make-icon.swift`, which the build
runs when it changes.

`legacyScreenSaver` keeps a loaded saver until it exits: after reinstalling by hand,
`killall legacyScreenSaver`. The screen saver logs to the unified log only:

```sh
/usr/bin/log show --predicate 'subsystem == "com.vastunghia.Mosaic"' --last 1h --style compact
```

## Strings and languages

What the app and the screen saver say lives in String Catalogs beside their sources:
`Hosts/App/Localizable.xcstrings`, `Hosts/App/InfoPlist.xcstrings` (the Photos permission's
text) and `Hosts/Saver/Localizable.xcstrings`. The build scripts compile them into the
bundles' `.lproj` folders with `xcstringstool`; there is no Xcode project.

```sh
./scripts/strings-sync.sh             # after changing what the interface says: add new keys, mark gone ones stale
./scripts/strings-sync.sh --check     # changes nothing, fails if the catalogs are behind (release.sh runs it)
```

The script builds the package apart, in `.build/strings`, for the compiler to list the
strings of each file: about 90 s the first time, seconds after. A string reaches the
catalog only from `String(localized:comment:)`, `LocalizedStringResource` or SwiftUI's
literals and `LocalizedStringKey` parameters, never from `NSLocalizedString`. In the screen
saver every string names `bundle: SaverLanguage.bundle, locale: SaverLanguage.locale`:
inside `legacyScreenSaver` the main bundle is the host's. Plurals are variations in the
catalog, English ones included: one key, `"\(n) albums"`, not a test on `n`.

To see what is not localized, launch the app with every localized string doubled; whatever
shows once was missed:

```sh
open ".build/bundle/Mosaic Companion.app" --args -NSDoubleLocalizedStrings YES
open ".build/bundle/Mosaic Companion.app" --args -AppleLanguages '(it)'   # another language
```

The screen saver follows the language of the system: a language set for
`legacyScreenSaver` alone does not reach it. Arguments do not reach it either, but its
container's preferences do, so it doubles its strings with:

```sh
P=~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/com.apple.ScreenSaver.Engine.legacyScreenSaver
defaults write "$P" NSDoubleLocalizedStrings -bool YES    # then killall legacyScreenSaver
defaults delete "$P" NSDoubleLocalizedStrings             # afterwards
```

Doubled, a plural with more than one number shows its raw `%1$#@name@` in the second
half: it reads right without the doubling.

## Running the effect on a folder

```sh
APP=".build/bundle/Mosaic Companion.app/Contents/MacOS/Mosaic Companion"

# Index a folder once. It is incremental: adding photographs later re-reads only those.
"$APP" --folder ~/Pictures/SomeFolder --build-index

# The effect in a window (space pause · ←/→ step a frame · f full screen · h hide),
# or full screen as the screen saver runs it.
"$APP" --folder ~/Pictures/SomeFolder
"$APP" --folder ~/Pictures/SomeFolder --play

# A single mosaic, held still, with its target photograph and its error map beside it
# and its numbers printed underneath.
"$APP" --folder ~/Pictures/SomeFolder --rows 60 --export-mosaic /tmp/mosaic.png

# Twenty mosaics at three settings, on one page: index.html shows each target, its
# mosaics, their error maps and their usage curves side by side, usage.html how often
# each photograph is used, and summary.csv and usage.csv have the numbers.
"$APP" --folder ~/Pictures/SomeFolder --export-batch ~/Pictures/mosaic-specimens/default \
    --penalties "" --tolerances 12,16,20

# A whole cycle, one PNG per frame.
"$APP" --folder ~/Pictures/SomeFolder --export-cycle /tmp/cycle --frames 240 --width 1280
```

`--index <dir>` keeps an index apart from the app's, which lives in
`~/Library/Application Support/Mosaic`.

Tile choice has knobs, because how good a mosaic looks is not something to settle by
argument: `--k 1|2|4|8` weighs average colour against structure (4 by default),
`--spacing` and `--tolerance` (16 by default) trade colour accuracy for variety — each
cell takes the least used photograph within that delta E of it — `--tolerance none
--repeat-penalty <p>` prices each repetition instead, `--max-uses` caps how many cells one
photograph may hold, `--seed <n>` replays a session (each launch otherwise takes a new
seed, printed at startup; exports always use a fixed one, so they regenerate
identically), `--candidates <n>` sets how many photographs of the shuffled deck each cycle
picks its subject among, so the photograph it zooms out of fits in (8 by default), and
`--subject <name>` pins the target so two settings can be compared on the same
photograph. `--rows` and `--duration` are the two settings the original exposed.

The error map shades every cell by its delta E on a fixed 0–40 scale, so two maps compare.
A batch also solves each target with every variety constraint off: that *floor* is the
closest the photographs can get at all, and the gap above it is the price of variety. A
batch is deterministic — the same folder and options give the same files, byte for byte.

## An optimised Photos library

With *Optimize Mac Storage*, Photos keeps few originals on the Mac, and Mosaic makes do
with the smaller copies it has: a photograph fills the screen only if this Mac has it at
854 pixels or more, and is a tile otherwise. These run on the Photos library, so launch
the app with `open -W --stdout <file> ".build/bundle/Mosaic Companion.app" --args …`, or the Photos
permission goes to the terminal.

- `--photos-library --probe-local N [--probe-csv <file>]` asks Photos, without the network,
  for the largest copy it has of `N` photographs, and whether their originals are here.
- `--photos-library --probe-quality N [--probe-serial] [--probe-csv <file>]` runs Vision's
  aesthetics on `N` photographs: on the upright image indexing decodes, on a second request
  at 427 pixels on the long side, and on the first scaled down to 427, with the times. Without
  `--probe-serial` it runs on every core, as indexing does. No network.
- `--photos-library --cull on` leaves screenshots, utility shots and the weakest photographs
  out of the subset, as the app does unless the user turned it off: Photos' scores from its
  database before the choice, Vision after decoding (log category `quality`). Off by default in
  the harness, so exports stay as they were. `--index-only` builds the index and stops, without
  the screen saver's close-ups, for timing a build.
- `--photos-library --export-culling <dir>` writes pages of what culling leaves out, month by
  month, and of every utility shot, with the verdicts the index at `--index` remembers: run it
  after a build with `--cull on`. Previews are what this Mac has at 256 pixels; nothing is
  downloaded.
- `./scripts/cull-probe.sh [--with-previews]` runs all of the above on this profile's own
  photographs, into a working index it deletes afterwards: a build from scratch without
  culling and with it, the same again, the culling pages and `--probe-quality 2048`, timed,
  with the log, in a zip on the Desktop. For another Mac or profile,
  `./scripts/package-cull-probe.sh` makes `.build/dist/mosaic-cull-probe.zip`, with the
  universal app and a README; whoever runs it sends back `cull-<user>-<Mac>.zip`. Without
  `--with-previews` only numbers and identifiers leave that Mac.
- `--photos-library --probe-download N` fetches `N` of the index's full-screen photographs
  from iCloud at 1920 pixels, one at a time, and says how long and how much it took. With
  `--close-up-anchor-width 640` it fetches tiles narrower than that instead, as for the
  anchor's ring. **It downloads**: it counts toward the user's disk and data.
- `--fetch-close-ups` builds the index and fetches as *Sharp close-ups only* does, within
  the same daily and weekly limits, so **it downloads** too. `--ring-share F` sets the share
  of the photographs brought to the ring's width (0.16 by default; 0 fetches none, as does
  `defaults write com.vastunghia.Mosaic ringShare -float 0` for the app).

On a library kept whole, `--export-batch … --compare-ring --simulate-sharp 0.16` shows what
an optimised one costs: each tolerance column comes twice, the ring around the anchor taking
any photograph in one and only those sharp enough in the other, as if only that share of
the photographs were. `--sharp-ring off` lifts the constraint altogether.

## Trying an update

The app reads GitHub's `releases/latest` once a day; `-updateFeed <url>` (one dash: two
open the harness) points it at a server of your own, which serves the same JSON. The new
version has to be signed with the same certificate as the running one.

```sh
echo 0.5 > VERSION && ./scripts/release.sh --allow-dirty; git checkout VERSION
mkdir -p /tmp/feed && mv .build/dist/Mosaic-0.5.dmg* /tmp/feed/
cat > /tmp/feed/latest.json <<'JSON'
{"tag_name": "v0.5", "body": "Notes, in Markdown.", "assets": [
 {"name": "Mosaic-0.5.dmg", "browser_download_url": "http://127.0.0.1:8765/Mosaic-0.5.dmg"},
 {"name": "Mosaic-0.5.dmg.sha256", "browser_download_url": "http://127.0.0.1:8765/Mosaic-0.5.dmg.sha256"}]}
JSON
(cd /tmp/feed && python3 -m http.server 8765 --bind 127.0.0.1) &
./Hosts/App/build.sh --install
open "/Applications/Mosaic Companion.app" --args -updateFeed http://127.0.0.1:8765/latest.json
```

Without a window, as a login item does, the update comes as a notification: write the
feed with `defaults write com.vastunghia.Mosaic updateFeed …`, delete `lastUpdateCheck`,
and launch with `open "mosaic://update?reason=test"`. Delete `updateFeed` afterwards.
The update category of the log says what happened.

## Renewing the subset

**Change photographs** in Settings chooses the subset again with a new seed. The new one is
built beside the live one, in `manifest-next.json` next to `manifest.json`. The two share
`thumbs/` and the close-up shelf, since every file is named after its photograph. Once the
new subset's index and its close-ups made from what this Mac has are ready, a `rename`
puts it in place.
The app deletes the files no manifest names only while no screen saver runs: the saver
reads a thumbnail and a close-up at every cycle, from the subset it started with. It
learns this from the `com.apple.screensaver.didstart` and `didstop` notifications. Behind
the lock screen the saver keeps running, and `didstop` comes only when the Mac is
unlocked.

- **Change Now** starts one at once, from the window.
- **Without a window**, as a login item does when the date comes: make one due, then call
  the app as the saver would. That call counts as a saver running, so the clean-up waits
  for a `didstop` or for a window to open.

  ```sh
  defaults write com.vastunghia.Mosaic subsetRenewedAt -date "2026-10-01 00:00:00 +0000"
  open "mosaic://update?reason=test"
  ```

The app category of the log says `renewing the subset started`, `renewal: … ready`,
`renewal: the new subset is in place` and, once nothing reads the old files,
`housekeeping: …`. A cycle the saver had to plan without the index shows as `a cycle fell
back to the stand-in mosaic` in its category; there should never be one.

## Starting from nothing

`scripts/uninstall.sh` takes Mosaic off the Mac for the profile that runs it: the app, the
screen saver, `~/Library/Application Support/Mosaic` and every other file the app, the
updater, the tests and the probes leave, the preferences, the login item, the Photos
permission (`tccutil reset All`), the notification settings and the help cache. It lists
what it found and asks first; `--dry-run` only lists. It stands alone, so it can be copied
to another Mac.

- Only the app can take back its login item, so the script calls it with
  `--unregister-login-item` before deleting it. A build from before that flag gets System
  Settings opened on Login Items instead.
- `tccutil` finds the bundle identifier through Launch Services, so the permissions are
  reset while the app is still there.
- Launch Services remembers every copy it has seen, those on the disk images of past
  releases included, and `lsregister -u` forgets one record at a time: the script repeats
  it until no record of the app or the saver points at a path that is gone. The copies
  still on disk, a build folder say, are named and left alone.
- Another profile keeps its own files and permissions: run the script there too.
- The unified log keeps Mosaic's messages until macOS rotates them away.

## The README's video

The loop in the README is an export of four cycles whose subjects come round again, so
the last frame is the first:

```sh
swift scripts/fetch-demo-corpus.swift ~/Pictures/mosaic-demo-corpus      # 2,048 CC0 photographs, ~1 GB
"$APP" --folder ~/Pictures/mosaic-demo-corpus --index ~/Pictures/mosaic-demo-index --build-index
"$APP" --folder ~/Pictures/mosaic-demo-corpus --index ~/Pictures/mosaic-demo-index \
    --close-ups stored --loop 106600.jpg,83078.jpg,44740.jpg,136301.jpg \
    --duration 15 --export-cycle ~/Pictures/mosaic-loop --frames 450 --width 1280
cmp ~/Pictures/mosaic-loop/0000.png ~/Pictures/mosaic-loop/closing.png   # the loop closes

# The animation in the README: AV1, a keyframe every half second, or Safari stutters.
ffmpeg -framerate 30 -i ~/Pictures/mosaic-loop/%04d.png -vf scale=640:-2 -c:v libsvtav1 \
    -crf 42 -g 15 -svtav1-params keyint=15 -pix_fmt yuv420p -f avif -loop 0 docs/media/mosaic-loop.avif

# The full-quality video the README links to, kept under 10 MB: two passes.
ffmpeg -framerate 30 -i ~/Pictures/mosaic-loop/%04d.png -c:v libx264 -preset slow -b:v 1266k \
    -pass 1 -an -f mp4 /dev/null
ffmpeg -framerate 30 -i ~/Pictures/mosaic-loop/%04d.png -c:v libx264 -preset slow -b:v 1266k \
    -pass 2 -pix_fmt yuv420p -movflags +faststart -an docs/media/mosaic-loop.mp4
```
