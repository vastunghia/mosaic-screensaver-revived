# Mosaic Screensaver Revived

A from-scratch reimplementation of the **Mosaic screen saver** that Apple shipped in Mac OS X
10.5 Leopard and removed in 10.8 Mountain Lion: an endless zoom outwards in which every photo
turns out to be one tile of a larger mosaic, which makes up another photo, and so on.

Nothing of the original implementation survives on macOS 15. This is a clean-room rewrite.

## Status

Milestone 2 closed: real photomosaics, built from a folder of photographs and judged as
stills. No Photos library yet, and no `.saver`: those are milestones 4 and 5.

## Building

```sh
./Hosts/App/build.sh          # builds and signs Mosaic.app
open .build/bundle/Mosaic.app # space pause · ←/→ step a frame · f full screen · h hide
swift test                    # colour, solver, folder, index and planner properties
```

## Running it on your own photographs

```sh
APP=.build/bundle/Mosaic.app/Contents/MacOS/Mosaic

# Index a folder once. It is incremental: adding photographs later re-reads only those.
"$APP" --folder ~/Pictures/SomeFolder --build-index

# A single mosaic, held still, with its target photograph and its error map beside it
# and its numbers printed underneath.
"$APP" --folder ~/Pictures/SomeFolder --rows 60 --export-mosaic /tmp/mosaic.png

# Twenty mosaics at three repetition penalties, on one page: index.html shows each
# target, its mosaics, their error maps and their usage curves side by side, usage.html how often each
# photograph is used in every column, and summary.csv and usage.csv have the numbers.
"$APP" --folder ~/Pictures/SomeFolder --export-batch ~/Pictures/mosaic-specimens/default

# Columns can be tolerances as well as penalties, or instead of them.
"$APP" --folder ~/Pictures/SomeFolder --export-batch ~/Pictures/mosaic-specimens/tolerance \
    --penalties 1 --max-uses 32 --tolerances 6,10,14

# The same thing moving.
"$APP" --folder ~/Pictures/SomeFolder --full-screen
```

Tile choice has knobs, because how good a mosaic looks is not something to settle by
argument: `--k 1|2|4|8` weighs average colour against structure (4 by default), `--spacing` and
`--tolerance` (16 by default, at the default `--k 4`) trade colour accuracy for variety — each cell takes the least
used photograph within that delta E of it — `--tolerance none --repeat-penalty <p>` prices
each repetition instead, `--max-uses` caps how many cells one photograph may hold, and `--subject <name>` pins the target so two settings can be compared
on the same photograph.

The error map shades every cell by its delta E on a fixed 0–40 scale, so two maps compare.
A batch also solves each target with every variety constraint off: that *floor* is the
closest the photographs can get at all, and the gap above it is the price of variety. A
batch is deterministic — the same folder and options give the same files, byte for byte.

Xcode and an *Apple Development* certificate in the keychain are required; without one the
build falls back to an ad-hoc signature, with a warning.
