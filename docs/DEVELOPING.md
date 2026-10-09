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
./Hosts/App/build.sh                  # .build/bundle/Mosaic.app, this Mac's architecture
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

## Running the effect on a folder

```sh
APP=.build/bundle/Mosaic.app/Contents/MacOS/Mosaic

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
