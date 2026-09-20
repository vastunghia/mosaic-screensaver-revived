# Mosaic Screensaver Revived

A from-scratch reimplementation of the **Mosaic screen saver** that Apple shipped in Mac OS X
10.5 Leopard and removed in 10.8 Mountain Lion: an endless zoom outwards in which every photo
turns out to be one tile of a larger mosaic, which makes up another photo, and so on.

Nothing of the original implementation survives on macOS 15. This is a clean-room rewrite.

## Status

Milestone 1 closed: the motion runs on synthetic photos, with a harness to judge it by.
No real photos yet, and no `.saver`: those are milestones 2 and 5.

## Building

```sh
./Hosts/App/build.sh          # builds and signs Mosaic.app
open .build/bundle/Mosaic.app # space pause · ←/→ step a frame · f full screen · h hide
swift test                    # the mathematical properties of MosaicCore and CycleEngine
```

Xcode and an *Apple Development* certificate in the keychain are required; without one the
build falls back to an ad-hoc signature, with a warning.
