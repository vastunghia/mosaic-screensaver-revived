# Spike 2 — the shared path between the app and the `.saver`

**Question.** Can the container app write the photo index somewhere the `.saver`, confined
to the `legacyScreenSaver` sandbox, can read it back from?

**Outcome: yes, and the right route is not the one we had assumed.** M11 gets a good deal
simpler. Details below.

## Method

Two sides that try the same five paths and write the outcome to the unified log:

| file | role |
|---|---|
| `Sources/main.swift` | the **app** side: tries to write a marker into every candidate |
| `Sources/PathProbeView.swift` | the **saver** side: tries to read the markers back and to write its own |
| `Sources/Probe.swift` | the list of candidates and the probes, shared by both sides |

The app side must be a real `.app`, signed and launched with `open`. Running it from a
shell would inherit the Terminal's TCC identity, which may hold permissions our app will
never have, and the result would be false. The same holds for any future test involving
TCC.

```sh
./build.sh
open build/MosaicSpike2Writer.app        # then select PathProbe in System Settings
/usr/bin/log show --last 20m --predicate 'subsystem == "dev.mosaic.spike2"' --style compact
```

## Results

| path | app writes | saver reads | saver writes |
|---|:--:|:--:|:--:|
| `legacyScreenSaver` container / Application Support | ✅ *(with a TCC prompt)* | ✅ | ✅ |
| `legacyScreenSaver` container / Preferences/ByHost | ✅ *(with a TCC prompt)* | ✅ | ✅ |
| **`~/Library/Application Support/`** | ✅ | ✅ | ❌ |
| `/Users/Shared/` | ✅ | ✅ | ✅ |
| `~/Pictures/` | ✅ | ✅ | ✅ |

### 1. The saver's sandbox allows reading outside the container

The `.saver` read from all five paths, including `~/Library/Application Support/`, which
lies outside its container.

Writing outside the container is denied where it matters
(`NSCocoaErrorDomain Code=513` on `~/Library/Application Support/`). That is sandbox
policy, not a POSIX permission problem: the files are `sergio:staff` with mode 755.

### 2. Writing into the `legacyScreenSaver` container trips TCC

From a different app, writing into the screen saver's container is not gated by POSIX
permissions but by the TCC service `kTCCServiceSystemPolicyAppData` ("app data",
introduced in Sonoma). With the app held waiting, `tccd` records:

```
AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyAppData, subject=dev.mosaic.spike2.writer
```

Once the permission is granted, the write succeeds. But it is a prompt in the user's face on
first launch, for a request that sounds invasive and would be hard to explain.

## Consequence: the design of M11

The starting assumption was that the app had to write inside the screen saver's
container. Result 1 makes that unnecessary, and result 2 makes it unpleasant as well.

> The app writes the index into `~/Library/Application Support/<app>/`, that is, into its
> own home, and the saver reads it from there. No TCC prompt, no writing into anyone else's
> container.

M11 therefore stops being an inter-process communication channel and becomes very little: a
path contract, with one side writing and one side reading, read-only.

The container is still needed for the saver's preferences: `ScreenSaverDefaults` writes
into the ByHost domain inside the container, and the saver writes there. But that is the
saver acting for itself, not the app acting for it: no boundary is crossed.

### Requirements that follow

- **The index must be replaced atomically** (write to a temporary file, then `rename`). The
  app may rewrite it while the saver is reading it, and there is no lock between the two
  processes: the atomicity of the rename is the only guarantee that the saver never reads a
  half-written file.
- **The saver treats the index as read-only.** That is not a matter of style: writing there
  is materially forbidden to it.
- **The saver cannot build the index.** If it is missing or incomplete, the saver has to
  degrade gracefully and defer to the app (already foreseen in M10, now confirmed).

### What stays open

- **If the app were ever sandboxed** (for the Mac App Store, say), it would write into its
  own container and the saver would have to read *from someone else's container*, something
  we have not tested from that side and which might require TCC in its turn. To be
  re-verified if and when distribution changes.
- **The saver's broad read access was measured on files we created ourselves.** That it can
  read any photo of the user's in `~/Pictures` is likely but not demonstrated; folders
  individually protected by TCC (Desktop, Documents, Downloads) are a different case and
  were not tested. Relevant only if one day the saver has to read photos itself instead of
  going through the index.
