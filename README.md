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

# A single mosaic, held still, with its target photograph beside it and its numbers
# printed underneath.
"$APP" --folder ~/Pictures/SomeFolder --rows 60 --export-mosaic /tmp/mosaic.png

# The same thing moving.
"$APP" --folder ~/Pictures/SomeFolder --full-screen
```

Tile choice has knobs, because how good a mosaic looks is not something to settle by
argument: `--k 1|2|4` weighs average colour against structure, `--spacing` and
`--repeat-penalty` trade colour accuracy for variety, and `--subject <name>` pins the
target so two settings can be compared on the same photograph.

Xcode and an *Apple Development* certificate in the keychain are required; without one the
build falls back to an ad-hoc signature, with a warning.
