# Spike 3 — PhotoKit across the sandbox boundary

**Question.** Are the thumbnails the app extracts from the Photos library usable by the
`.saver` without re-authorisation? And how fast can the index be built?

**Outcome: yes, with no friction at all.** The saver does not even import `Photos`: it reads
files, and that is it. The surprise is not there but in the numbers, which change the design
of M5.

## Method

| file | role |
|---|---|
| `Sources/main.swift` | the **app** side: authorises, indexes 200 photos, writes index and thumbnails |
| `Sources/bench.swift` | measurement bench: separates the phases and compares five strategies |
| `Sources/ThumbGridView.swift` | the **saver** side: reads the index back and draws the thumbnails |
| `Sources/Index.swift` | the index format, shared by both sides |

The saver draws every thumbnail with a strip of its own average colour underneath: if the
two match by eye, the computed colour crossed the boundary intact as well. Verified
visually.

```sh
./build.sh
open build/MosaicSpike3Indexer.app              # index
open build/MosaicSpike3Indexer.app --args bench # measure
/usr/bin/log show --last 10m --predicate 'subsystem == "dev.mosaic.spike3"' --style compact
```

## Results

### 1. The chain holds — ✅

- Authorisation granted to an **ad-hoc signed** app: `authorized`. It needs
  `NSPhotoLibraryUsageDescription` in the `Info.plist`; without it no prompt appears at all.
- Test library: **54,169 images**, all available locally
  (`PHImageResultIsInCloudKey` never true, 0 skipped).
- The saver read the index and loaded 120 thumbnails out of 120, **without importing
  `Photos`** and without any authorisation. Spike 2 confirmed on real data.

### 2. The first measurement round was wrong, and badly so

The first indexing run gave **30.2 photos/s**, that is ~30 minutes for the whole library —
a number that would have forced heavy constraints on M5. Separating the phases over 100
assets:

| strategy | photos/s | whole library |
|---|---:|---:|
| 512×288 extraction, `highQualityFormat`/`exact` | 198 | 4.6 min |
| 512×288 extraction, `fastFormat`/`fast` | 2926 | 0.3 min |
| 256×144 extraction, `highQualityFormat`/`exact` | 284 | 3.2 min |
| 128×72 extraction, `fastFormat`/`fast` | 9088 | 0.1 min |
| **original data + `CGImageSource`** | **33** | **27.7 min** |
| JPEG encode (image already in memory) | 385 | — |
| average colour, a fresh `CIContext` every time | 113 | — |
| **average colour, shared `CIContext`** | **304** | — |

Three conclusions:

- **PhotoKit was not the bottleneck.** Extraction runs at 198 photos/s; the 30 were largely
  my own inefficiency.
- **The `CIContext` has to be shared**: creating one per image costs 2.7×. It is the mistake
  I had made, and it is extremely easy to repeat.
- **Do not read the originals.** The "request the original data and resample with
  `CGImageSource`" route, which looked like the obvious optimisation, is **six times
  slower**: it re-reads whole multi-megabyte files from disk. PhotoKit's derivatives exist
  precisely for this.

### 3. Two caveats about the numbers, not to be hidden

- **The bench ran over the same assets the indexing had already touched**, hence with
  PhotoKit's derivatives already warm. The 198 photos/s is a **warm** rate; the 30.2 of the
  first round were cold *and* with the inefficient code. The real cold cost lies between the
  two and **was not measured**. It has to be redone on assets never touched before.
- **`fastFormat` is too fast to be free.** In all likelihood it returns a small
  ready-made derivative, not an image at the requested size. We did not verify the actual
  dimensions of what comes back, so those 2926 photos/s **cannot be spent** until someone
  checks what they really contain.

### 4. Cost on disk

The 200 thumbnails at 512×288, JPEG quality 0.8, weigh **40.8 KB on average**: about
**2.1 GB** for the whole library. The JSON index, without the pixels, is ~245 bytes per
entry.

### 5. Ad-hoc signatures lose the authorisation on every build

Rebuilding the app changes its `cdhash`, and TCC treats it as a new application: the state
goes back to `notDetermined` and the prompt returns. With an ad-hoc signature it has to be
re-authorised on every build, which makes working on M4 and M5 unbearable. **A stable
signing identity is needed from the very start of development**, not only at distribution
time.

## Consequences for the plan

**Indexing the whole library is neither necessary nor worthwhile.** With `R = 20` a mosaic
uses 400 tiles; a few thousand photos are an ample pool. Against that, 54,000 photos cost
2.1 GB and minutes of waiting — only to draw 400 at a time from them.

So M5 has to index **by subset and incrementally**: become usable quickly with the first N
photos and carry on in the background, saving its progress. It is also the cure for the
historical flaw of the original, which barred the way with "Creating photo database" until
it was done.

A new design question comes out of this, and it belongs to the spec because it is visible on
screen: **how is the subset chosen?** The most recent photos give a coherent but monotonous
mosaic; a random sample draws from the whole library but mixes eras and styles; a uniform
distribution over time is the middle road. It is not a technical choice: it changes what you
see.
