# Mosaic

The Mosaic screen saver from Mac OS X Leopard, rebuilt from scratch for macOS 15 and
later, on your own photographs.

<img src="docs/media/mosaic-loop.avif" width="640" alt="A photograph of a red teapot zooms out until it is one tile of a mosaic of sunflowers, which zooms out into a tree against the sky, then a red heart held in a hand, and back to the teapot.">

An endless zoom outwards: every photograph turns out to be one tile of a larger mosaic,
which makes up another photograph, which is one tile of the next mosaic, and so on.
Apple shipped it in Mac OS X 10.5 and dropped it in 10.8. Nothing of the original survives
on today's macOS, so this is a clean-room reimplementation, drawn with Metal.

The loop above is 60 seconds at 640 pixels; [download it at 1280 pixels](docs/media/mosaic-loop.mp4)
(MP4, 9.5 MB).

## What you need

- macOS 15 Sequoia or later.
- A Mac with Metal (any Mac that runs macOS 15).
- Photographs: your Photos library, or a folder of them. At least 100; a couple of
  thousand look best.

Mosaic has been tested on an Intel Mac. The app is a universal binary and runs on Apple
silicon too, but nobody has watched it there yet: if you do, please say how it went.
It shows its mosaic on the main display; other displays stay black.

## Installing

1. Download `Mosaic-x.y.dmg` from the [latest release](https://github.com/vastunghia/mosaic-screensaver-revived/releases/latest),
   open it and drag **Mosaic** to **Applications**.
2. Open Mosaic from Applications. macOS says *"Mosaic" Not Opened*: choose **Done**.
3. Open **System Settings › Privacy & Security**, scroll down to *"Mosaic" was blocked
   to protect your Mac* and choose **Open Anyway**, then confirm with your password.
   You only do this once.
4. Mosaic opens on its setup steps:
   - **Photographs** — allow access to your Photos library, or choose a folder;
   - **Preparation** — Mosaic makes a small copy of each photograph to build mosaics from;
     this runs by itself, and the mosaic appears in the window as soon as 100 are ready;
   - **Screen Saver** — **Install**, then choose **Mosaic** in the Screen Saver settings,
     under *Other*.

Why step 3: Mosaic is signed, but not notarized by Apple, which takes a paid developer
membership. macOS therefore asks you, once, whether you trust it. If you would rather not,
[build it yourself](#building-from-source).

## Using it

The window shows the mosaic moving; click it, or press **⌘↩**, to watch it full screen.
**Mosaic › Settings…** (⌘,) chooses which photographs (albums, how many, how they are
picked over time), how many rows a mosaic has, and how long each zoom lasts.

Mosaic opens at login, without a window, to keep the screen saver's photographs up to
date as your library changes. You can turn that off in Settings.

## Your photographs

They never leave your Mac. Mosaic reads them through the Photos library (or the folder you
chose) and keeps, in `~/Library/Application Support/Mosaic`, a small copy of each and a
larger one for close-ups: about 1.2 GB for 2,048 photographs. The screen saver reads only
those copies; it never touches the Photos library.

## Uninstalling

Quit Mosaic, then delete:

- `/Applications/Mosaic.app`
- `~/Library/Screen Savers/Mosaic.saver`
- `~/Library/Application Support/Mosaic`

and remove Mosaic from **System Settings › General › Login Items & Extensions**, if it is still there.

## Building from source

You need Xcode 26 or later.

```sh
./Hosts/App/build.sh --install   # builds the app (with the screen saver inside) into /Applications
./scripts/release.sh             # the universal app on a disk image, as released
swift test
```

Signing matters more than usual here, because the Photos permission is tied to the app's
signature. With an *Apple Development* certificate in your keychain the build is signed
with it, and macOS remembers the permission from one build to the next. Without one, the
build falls back to an ad-hoc signature, which works but asks for the permission again
after every build.

How the effect is put together, and the tools used to tune it, are in
[docs/DEVELOPING.md](docs/DEVELOPING.md).

## Credits

The photographs in the video come from the [WordPress Photo Directory](https://wordpress.org/photos/),
which publishes them under CC0. `scripts/fetch-demo-corpus.swift` downloads the same 2,048
photographs, with a `credits.csv` that links each one to its page.

Mosaic is an independent tribute to a screen saver Apple made, and is not affiliated with
or endorsed by Apple.

## License

[MIT](LICENSE).
