# Spike 1 — Metal inside `legacyScreenSaver`

**Question.** Can a third-party `.saver` draw with Metal inside the sandboxed
`legacyScreenSaver` process? At what rate? And what diagnostics can we get out of it?

If there were a wall here, module M7 of the plan would have to be rethought and milestone 5
(the screen saver proper) would be at risk. The stand-alone app would stay intact, which is the reason the
deliverable was designed this way.

**Outcome: no wall.** Metal runs at 60 fps inside `legacyScreenSaver` with ample headroom.
Details and numbers below.

## What is here

| file | what it does |
|---|---|
| `Sources/MetalSpikeView.swift` | a `ScreenSaverView` that draws a spinning triangle with Metal and measures fps and GPU time |
| `Sources/Shaders.metal` | vertex and fragment shaders, precompiled into `default.metallib` |
| `Sources/host.swift` | **control experiment**: loads the same bundle in an ordinary window, outside the sandbox |
| `build.sh` | builds the `.saver` and installs it into `~/Library/Screen Savers/` |

The control host is there to separate *"my Metal code is wrong"* from *"the screen saver
environment forbids it"*. Without it, a failure inside `legacyScreenSaver` would be
ambiguous, in an environment where you cannot even print to stderr.

## How to run it

```sh
./build.sh                     # builds and installs
xcrun swiftc -target "$(uname -m)-apple-macos15.0" \
    -o build/host Sources/host.swift -framework ScreenSaver -framework AppKit
./build/host                   # control, outside the sandbox

# diagnostics (the only channel inside legacyScreenSaver):
/usr/bin/log show --last 5m --predicate 'subsystem == "dev.mosaic.spike"' --style compact
```

Note: on this Mac `log` is shadowed by a shell function, so `/usr/bin/log` is needed.

## Results

### Outside the sandbox (control) — ✅

On an Intel 4K Retina iMac with the integrated Radeon Pro 560X, 960×540 window
(the machine also has an RX 6800 in a Thunderbolt eGPU, not attached during these measurements):

```
device=AMD Radeon Pro 560X low-power=false unified-memory=false max-buffer=3072MB
fps=60.0 gpu=0.199ms/frame
```

A steady 60 fps, ~0.2 ms of GPU per frame, `nextDrawable()` never nil. The bundle built
from the command line loads and its `principalClass` resolves correctly. This is the lower
bound of the hardware we care about.

### Inside `legacyScreenSaver` — ✅

MetalSpike selected in System Settings, on a 4K Retina iMac (4096×2304 panel, interface at
2560×1440 points, hence a 5120×2880 ≈ 14.7 Mpixel drawable).

```
process=legacyScreenSaver preview=true  frame=143x80     fps=60.0  gpu=0.015ms
process=legacyScreenSaver preview=false frame=2560x1440  fps=60.0  gpu=1.035ms
sandbox: APP_SANDBOX_CONTAINER_ID=com.apple.ScreenSaver.Engine.legacyScreenSaver
HOME=/Users/sergio/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data
```

**Metal works inside the sandbox.** A constant 60 fps both in preview and
full screen, `nextDrawable()` never nil, no error message, no behavioural difference from
the host outside the sandbox. The Metal device is the same one: no software fallback, no
low-power device.

None of the worries that motivated this spike materialised.

### Two side observations

The preview stays alive. With System Settings open behind the full-screen saver, two
instances run in distinct processes, both at 60 fps. In that condition the GPU time of the
full-screen instance rises from 1.03 to ~2.25 ms: real contention, but on a transient
configuration that only occurs while the user is in the settings pane. The performance of
the product has to be measured with System Settings closed, or the numbers double.

Half the answer to spike 2, for free. Inside the saver, `NSHomeDirectory()` is
`~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data`, not the user's
home. The container is the documented one, shared by every third-party `.saver`. It is the
natural candidate for the index the app has to write and the saver to read, and whether the
app can write there remains to be verified.

### Headroom for the real effect

The triangle covers about a quarter of the drawable. The effect the spec describes will
cover the whole screen with textured quads sampled from mips, so the fill cost will be
several times higher: a rough estimate of 4–6 ms per frame, against a budget of 16.6 ms
at 60 fps.

It is an estimate extrapolated from a flat-shaded triangle, not a measurement: the real
number will come from milestone 1. But the headroom is wide enough that nothing needs
redesigning.

## Two traps found along the way

Neither of them is about Metal, but both would cost hours if met in production code, and
both fail silently.

### 1. The bundle link must be driven by `swiftc`, not by `clang`

Building in two steps, `swiftc -emit-object` and then `clang -bundle`, yields a bundle
that loads, runs and *looks* like it works, but dies with SIGSEGV on the first read of any
Swift global stored property, even a trivial `let x = "OK"` at file scope. The crash says
nothing useful and looks like a sandbox or a Metal problem.

The cause is that `clang` does not run the link steps specific to the Swift runtime. The
cure is to let `swiftc` do the linking:

```sh
xcrun swiftc -emit-library -o Contents/MacOS/Name Sources/*.swift \
    -Xlinker -bundle -Xlinker -rpath -Xlinker /usr/lib/swift
```

### 2. In `os_log`, `type:` must be a literal

```swift
os_log("%{public}@", log: osLog, type: error ? .error : .default, message)  // ❌ disappears
os_log("%{public}@", log: osLog, type: .error, message)                     // ✅
```

With an expression in place of the literal the message never reaches the unified log,
with no error and no warning. In a context where the log is the only diagnostic channel,
that means believing the code is not running at all.

Corollary for production code: the shared logging function has to branch over levels with
`if`/`switch` and call `os_log` with a literal type in every branch. It goes into the plan
when there is a diagnostics module.
