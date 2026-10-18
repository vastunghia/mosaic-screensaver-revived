# Spike 5: where the aesthetic score comes from

Mosaic should leave out bad photographs and utility shots (receipts, documents,
invoices, handwriting, illustrations) before it picks the subset it indexes. Photos
already computes an aesthetic score and sorts utility shots into collections of its
own, and keeps both in the library's private databases. Vision computes a similar
score, with an `isUtility` flag, through a public API
(`CalculateImageAestheticsScoresRequest`). This spike decides which of the two
Mosaic Companion uses.

The database has one advantage Vision cannot match: it scores the **whole library**
before the subset is chosen, without decoding a single photograph. Vision can only
score what has already been decoded, so it can filter the subset but not shape it.

## What the database holds (macOS 15.7.9, a 54,862-photo library)

Read with `sqlite3`, read only.

- `ZASSET.ZOVERALLAESTHETICSCORE`: every photo has one. It runs from 0 to 1, averages
  0.47, and is bell-shaped. `ZCURATIONSCORE` has 12,416 distinct values, but 38 % of
  the photos sit at exactly 0.5, so it ranks poorly.
- `ZCOMPUTEDASSETATTRIBUTES` holds 25 sub-scores (`ZFAILURESCORE`, `ZNOISESCORE`,
  `ZSHARPLYFOCUSEDSUBJECTSCORE`, …). `ZMEDIAANALYSISASSETATTRIBUTES` adds
  `ZBLURRINESSSCORE` and `ZEXPOSURESCORE`.
- **There is no `isUtility` column.** Utility shots show up in three other places:
  - Photos' own Utilities collections, in `database/search/psi.sqlite` (`groups`,
    category 2800, `utilityCollection/1…4`): Documents 260, Receipts 9,
    Illustrations 310, Handwriting 400.
  - Scene labels, in `ZSCENECLASSIFICATION`, with localized names in `psi.sqlite`
    (category 1500). At confidence > 0.5, *document* (`scene/492`) tags 1,249 photos,
    and those average an aesthetic score of 0.28.
  - Screenshots: `ZASSET.ZISDETECTEDSCREENSHOT` (165).

## Question 1: can an app with only the Photos permission read the databases?

**Yes. The Photos permission is enough, and nothing short of it works.** Full Disk
Access is not needed.

`Spike5Probe.app` (`./build.sh`) has its own bundle identifier, so its TCC grants
start empty. It reports its Photos authorization, then tries places guarded by Full
Disk Access (`~/Library/Mail`, `~/Library/Safari`, the user TCC folder) as a positive
control. If it could list those, it would not be under TCC at all and the rest would
prove nothing. Then it lists the library, and opens `Photos.sqlite` and `psi.sqlite`
with `open(2)` and with SQLite (`mode=ro` and `mode=ro&immutable=1`). It runs through
`open -W --stdout`, so TCC sees its own identity.

| run | Photos | FDA paths | library listing | `open(2)` | SQLite |
|---|---|---|---|---|---|
| probe, Photos denied | denied | 257 (denied) | 257 | `EPERM` | rc 23, *authorization denied* |
| probe, Photos granted | authorized | 257 (denied) | ok | ok | ok, 54,862 / 54,510 in 45 ms |
| Terminal (control: FDA + Photos) | authorized | — | ok | ok | ok, same counts |

What else the runs showed:
- **The file access itself raises the Photos prompt.** The first time an app without
  a Photos decision touches the library bundle, `sandboxd` asks `tccd` for
  `kTCCServicePhotos` and the call blocks until the user answers: 90 s in the first
  run. This prompt offers *Don't Allow*, *Allow Full Access* and *Limit Access…*.
  So the database must only be read after the PhotoKit request has been answered.
  Code that reads it earlier blocks on this prompt.
- `stat(2)` works even when access is denied. Only opening the file is refused.
- `photolibraryd` was running with a live WAL (3.7 MB) and `mode=ro` read it without
  trouble. `immutable=1` ignores the WAL, so it can miss recent changes. **Use
  `mode=ro`.**
- The full query over `ZASSET` takes 45 ms on a 3 GB database.

On macOS 26.6.2 (an A18 Pro) the same holds: see the remote runs under question 4.

Still open:
- **Limited access.** Not tried. With *Limit Access* PhotoKit only sees the chosen
  photos, and it is not known whether the files stay readable. Mosaic Companion asks
  for full access, so this matters only if a user picks the limited option.

## Question 2: where the system library is

**`PHPhotoLibrary.photoLibraryURL`, checked against PhotoKit's own identifiers.**

The name cannot be guessed. On this Mac the system library is `~/Pictures/Foto
Library.photoslibrary`: the default name, localized when the library was created.
Next to it sits an old `Photos Library.photoslibrary`, 2.6 MB from 2023, that is not
the system library. A hard-coded `Photos Library` would read the wrong database
without any error.

`./build.sh`, then `open -W --stdout out.txt build/Spike5Probe.app --args --match`:

| source | what it is | result |
|---|---|---|
| `PHPhotoLibrary.shared().photoLibraryURL` | private property, read by KVC after `responds(to:)` | the right library |
| `com.apple.cloudphotod`, `CPLEngineParameters-SystemLibrary.clientLibraryBasePath` | a plain preferences file in `~/Library/Preferences` | the right library, but present only with iCloud Photos on |
| `com.apple.Photos` (`IPXDefaultLibraryURLBookmark`), `com.apple.photolibraryd` | preferences inside those apps' containers | not readable: `CFPreferences` returns nothing, from the app and from Terminal |

Both private sources can disappear in some macOS release. So a path is never trusted
on its own: it is accepted only if PhotoKit's identifiers are in its `ZASSET` (question
3). Then a wrong path means no score, and the effect is the same as having no
database. If neither source answers, the fallback is the same check on every
`*.photoslibrary` in `~/Pictures`. The containers are left alone: reading another
app's container would bring up the *access data from other apps* prompt.

## Question 3: do PhotoKit's identifiers match the database's?

**Yes, all of them.** Every `localIdentifier` has the form `<UUID>/L0/001`, and the
UUID is `ZASSET.ZUUID`.

- PhotoKit returns 54,267 images (with `includeHiddenAssets` and
  `includeAllBurstAssets`) in 2.2 s. **All 54,267 are in `ZASSET`**: none is missing,
  none is marked trashed, none is of another kind.
- The full `ZASSET` read takes 100 ms (59,759 rows, videos included).
- The database has 595 images (kind 0, not trashed) that PhotoKit does not return:
  522 with `ZHIDDEN` = 1 and 73 with `ZVISIBILITYSTATE` = 2. They are filtered out by
  the join anyway, so they need no rule of their own.
- **Coverage: every visible photo has a score** (54,194: not hidden, not a burst
  member left out). None is `NULL`.
- **The score runs from 0 to 1.** Above 0 it runs from 0.00057 to 1.0, averages 0.476,
  and comes in steps of powers of two (0.990234375 = 1014/1024), probably a
  half-precision float.
- **0 is a real score, the bottom of the scale.** It is not a missing one. Below 0.1
  the distribution is smooth, about 30 photos per 0.01, but exactly 0 holds 352: the
  score is clamped, and everything that would fall below 0 lands on it. The sub-scores
  agree, since the photos at 0 are the worst in the library by Photos' own measures:

  | band | photos | `ZFAILURESCORE` | `ZPLEASANTCOMPOSITIONSCORE` | `ZCURATIONSCORE` |
  |---|---|---|---|---|
  | = 0 | 352 | −0.066 | −0.40 | 0.30 |
  | 0–0.05 | 163 | −0.050 | −0.42 | 0.35 |
  | 0.05–0.3 | 4,519 | −0.020 | −0.54 | 0.54 |
  | 0.3–0.7 | 46,248 | −0.004 | −0.17 | 0.61 |
  | ≥ 0.7 | 2,913 | −0.001 | +0.30 | 0.64 |

  The sub-scores are signed, from −1 to 1. Only `NULL`, or a photo missing from
  `ZASSET`, means "no score".

## Questions 5–7: Vision against the database, on the 2048 indexed photos

The corpus is Mosaic's own index: 2048 photos chosen `uniformInTime` from the 54,194
of the library. They are PhotoKit identifiers, so each one is also a `ZASSET` row.

```sh
./build.sh
OUT=~/Pictures/mosaic-specimens/spike5-aesthetics
open -W --stdout "$OUT/vision-run.txt" build/Spike5Probe.app --args --vision "$OUT" --sizes 854,427
python3 -I analyze.py "$OUT"          # summary.txt and index.html
```

The probe asks PhotoKit for the whole photograph (`aspectFit`, `.fast` resize,
`highQualityFormat`, no network) and runs `CalculateImageAestheticsScoresRequest` on
it, one photo at a time. The page has the worst, median and best 64 by each score,
the largest disagreements, and the photos each utility criterion flags alone.

### 5. Cost and agreement

iMac 2019 (Intel, Radeon Pro 560X; eGPU state not recorded), macOS 15.7.9, one
photo at a time:

| size | PhotoKit fetch | Vision | Spearman with Photos |
|---|---|---|---|
| 854 px | 43.5 ms | 50.5 ms (p95 52.2; first call 264 ms, 2 s cold) | 0.922 |
| 427 px | 6.3 ms | 48.6 ms (p95 49.9) | **0.964** |

- **Vision's cost does not depend on the input size**: it scales the image down
  itself. Scoring the whole index costs about 100 s per 2048 photos on top of
  indexing. Scoring the whole library (54,000 photos) would cost about 50 minutes.
- **Vision at 427 px ranks the photos almost as Photos does.** The two sizes agree with
  each other less (0.916) than 427 agrees with Photos, so Photos probably scores a small
  derivative.
- The scales differ. Vision runs from −1 to 1 (−0.99 … 0.93 here), Photos from 0 to 1.
  Photos is not `max(0, Vision)`: Vision puts 73 photos below 0 at 427 px, while
  Photos has 16 at 0. The two can share a ranking, not a threshold.
- The worst 64 by Photos are rejects: timetables, documents, black frames, pocket
  shots, slides. Vision's worst 64 at 854 px are rejects too, plus some night scenes
  and dim shots of people that Photos keeps in the middle. Where the two disagree most,
  neither is plainly wrong: ordinary family photos around 0.4, night skies, sunsets.

### 6. The specimen

`~/Pictures/mosaic-specimens/spike5-aesthetics/index.html`. Thresholds are still to
be chosen there by eye.

### 7. Utility shots

| criterion | flagged among 2048 | what it flags on its own |
|---|---|---|
| Vision `isUtility`, 854 px | 138 | **99, nearly all genuine**: meters, an ID card, posted notices, stoves and bathrooms photographed for a repair, products in shops, a dent in a car |
| Vision `isUtility`, 427 px | 110 (105 shared with 854) | fewer than at 854 |
| Photos' Utilities collections (`psi.sqlite`) | 44 (Illustrations 19, Handwriting 17, Documents 12, Receipts 1) | 9, mostly wrong: portraits as *Handwriting*, church interiors and a blurred flower as *Illustrations* |
| scene labels, strict set, confidence ≥ 0.5 | 83 | 45, mostly wrong: people in front of bookshelves as *book* + *document*, people at a computer as *computer monitor* |
| `ZISDETECTEDSCREENSHOT` | 9 | 8 of them also flagged by Vision |

- **The database has nothing that does what `isUtility` does.** The Utilities
  collections and the scene labels flag a different set, and on their own they are
  mostly false positives.
- **The aesthetic score alone does not catch utility shots.** They score low (median
  0.30 for Photos) but not lowest. Dropping the worst 10 % by Photos removes 204 photos
  and only 63 of the 138; at 20 % it removes 409 and still misses 44.

## Question 4: a second profile on the same iCloud library

A second profile on the same iMac: same iCloud library, *Optimize Mac Storage* on,
rarely logged in. Launched from that profile's Terminal:

```sh
cd /tmp/mosaic-probe/spike5 && open -W --stdout /tmp/mosaic-probe/spike5/second-match.txt \
    Spike5Probe.app --args --request --match --dump /tmp/mosaic-probe/spike5/second-assets.csv
```

The CSV was compared with the same dump of Sergio's library (`--match --dump`).
The two were joined on `ZCLOUDASSETGUID`.

- **Questions 1–3 hold there too.** With the Photos permission alone the probe read
  the database. `photoLibraryURL` and `cloudphotod` both found `~/Pictures/Photos
  Library.photoslibrary`, a different name from Sergio's. All 57,672 PhotoKit images
  are in `ZASSET`.
- **`ZUUID` is local to each library.** No UUID is shared between the two profiles.
  The same photo is recognized by `ZCLOUDASSETGUID` (52,758 in common). This does not
  matter to Mosaic, which only ever reads the library of the profile it runs in.
- **The analysis is local, not synced.** On photos analysed on both profiles the
  scores differ (median gap 0.068; identical in 1,885 of 52,758). They rank alike,
  though: Spearman 0.964.
- **On a profile that is rarely used, most photos have no real score.** 44,556 of
  57,672 have `ZMEDIAANALYSISVERSION` = 0. The analysis ran mostly on 2025-12-29 and
  during the October 2026 tests, and covers recent years more than old ones. The
  photos it has not reached do not have `NULL`. They carry a **placeholder: score
  exactly 0.5 and no `ZFAILURESCORE`** (0 or `NULL`); here `ZCURATIONSCORE` is 0 too,
  but not on every Mac (see the remote runs below). Their ranking against
  Sergio's is noise (Spearman 0.155).
- The placeholder is the marker to use, not the version alone. 1,562 photos with
  version 0 have a real score (Spearman 0.969 with Sergio's), and 0.5 is also a real
  value: 223 analysed photos in Sergio's library have it. The rule *0.5 and failure 0
  or `NULL`* flags 43,731 photos on the second profile (76 %). On
  Sergio's it flags 74: the one unanalysed photo and the 73 burst members PhotoKit
  hides anyway.

So the database score cannot be the only source. On a profile like the second one, three
photos in four have none, and the ones that have one lean towards recent years.

## Remote runs, 2026-10-17

`run-remote.sh` and the universal `Spike5Probe.app` went to three more profiles in one
zip; `remote.py` reads what they send back (identifiers and numbers, no photographs).
Sergio's own profile on the iMac was run again as a control.

```sh
python3 -I remote.py <results dir>...
```

| profile | Mac, macOS | visible images | placeholder | Vision 854 local | 427 local | Spearman 854 / 427 | worst 10 % 854 / 427 |
|---|---|---|---|---|---|---|---|
| Sergio (control) | iMac19,2 i5, 15.7.9 | 54,267 | 74 (0.1 %) | 1024 of 1024 | 1024 | 0.912 / **0.957** | 0.70 / 0.77 |
| Second profile | same iMac | 57,675 | 43,731 (76 %) | 94 | 1022 | 0.953 / 0.901 (256 scored) | 0.56 / 0.31 |
| Another user's laptop, used daily | Intel i3, 15.7.9 | 57,672 | 29,796 (52 %) | not run | not run | — | — |
| Another user, own library | Apple A18 Pro, **26.6.2** | 4,738 | 312 (6.6 %) | 680 | 1015 | **0.932** / 0.919 | 0.51 / 0.22 |

- **Question 1 holds on macOS 26.** On the A18 Pro the probe started without the Photos
  permission, asked for it, got it, and read `Photos.sqlite` (5,142 assets in 22 ms)
  with nothing else granted. Questions 2 and 3 hold on all four: `photoLibraryURL` and
  `cloudphotod` agree, and every PhotoKit image is in `ZASSET` (4,738, 57,675, 57,672,
  54,267). The analysis version there is 77 (70 on macOS 15).
- **The placeholder has a second shape.** On the i3 laptop, 28,799 unanalysed photos carry
  score 0.5 with `ZCURATIONSCORE` **0.5**, not 0, and failure exactly 0. The rule is now
  *score exactly 0.5 and failure 0 or `NULL`*, whatever the curation. On all four
  profiles no photo has failure 0 or `NULL` with another score but one, and only 2–76
  photos per profile have 0.5 with a real failure score, so the rule does not depend on
  the curation level a Mac happens to write.
- **A profile used every day still has half its photos unscored.** On the i3 laptop 52 %
  of the photos carry the placeholder, against 76 % on the iMac profile that is seldom
  used. Its 15,710 version-0 photos with a real score rank like Sergio's (Spearman
  0.965) as do the analysed ones (0.972). The laptop and the iMac agree with each other
  far more (0.993 on 13,940 photos) than either does with Sergio's profile (0.966):
  some scores may come from the same device through iCloud, not from each Mac.
- **Vision on Apple Silicon:** 10–12 ms a photo on the A18 Pro, against 47–53 ms on
  the i5; fetching the 427 px image costs 5 ms on both. There 854 px ranks closer to
  Photos than 427 px, the opposite of the Intel iMac. That library is a different
  kind: 1,053 of 4,738 images (22 %) are screenshots, and `isUtility` flags a third of
  the remaining photos. Without screenshots the agreement is 0.947 at 854 and 0.942 at
  427; with them only, 0.887 and 0.893.
- **The i3 laptop sent no Vision results.** Its zip has no `vision-run.txt`: the second step
  of `run.sh` did not start, so there is no measure of the derivatives that a profile
  used every day keeps locally.

## Mapping Vision onto Photos' scale

The two scales differ, but the two scores rank photos almost alike, so a monotone map
by quantiles converts one into the other. A Vision score goes to its quantile among
Vision scores, then to Photos' score at the same quantile. `calibrate.py` fits the
map on one half of the 2048 and judges it on the other (two folds, by UUID). The
yardstick is how far Photos disagrees with itself: the same photo analysed on
Sergio's and on the second profile. *Same worst x %* is the share of the photos that
Photos puts in its worst x % which the estimate puts there too.

```sh
python3 -I calibrate.py "$OUT/sergio-assets.csv" second-assets.csv "$OUT/vision.csv" "$OUT/small/vision.csv"
```

| estimate of Photos' score | Spearman | \|gap\| median | p90 | same worst 5 % | 10 % | 20 % | `isUtility` (of 138 at 854) |
|---|---|---|---|---|---|---|---|
| Photos on another profile | 0.966 | 0.014 | 0.056 | 0.92 | 0.91 | 0.90 | — |
| Vision 854 px, mapped | 0.921 | 0.032 | 0.093 | 0.60 | 0.72 | 0.81 | 138 |
| **Vision 427 px, mapped** | **0.963** | 0.021 | 0.057 | 0.51 | 0.79 | 0.89 | 110 (105 shared) |
| Vision 320 px, mapped | 0.908 | 0.032 | 0.096 | 0.28 | 0.65 | 0.80 | 89 (86) |
| Vision 256 px, mapped | 0.884 | 0.037 | 0.113 | 0.22 | 0.55 | 0.75 | 80 (76) |

- **The map is close to the identity above 0.3.** At 427 px it sends 0.4 to 0.42, 0.6
  to 0.62 and 0.8 to 0.84. It bends only at the bottom, where Vision goes negative and
  Photos stays at 0–0.2: −0.4 goes to 0.08 and 0 to 0.22. Unmapped, the median gap is
  already 0.027.
- **Overall, 427 px is as close to Photos as Photos is to itself.** In the tail it is
  not: it agrees on half of the worst 5 %, against 92 % between two Photos runs.
  That is where a threshold cuts.
- **Smaller is worse, and that is what an *Optimize Mac Storage* profile has**
  (derivatives from 256 px). At 256 px the worst 10 % agree on 55 % and `isUtility`
  finds 80 of 138. A 256 px request returns 256–265 px.
- Vision's cost stays at 47–50 ms whatever the size.

## What this means

- **Aesthetic score: from the database where it has one.** It covers the whole library
  before the subset is chosen, costs one 100 ms query, needs only the Photos permission,
  and matches PhotoKit's identifiers one for one. Photos with the placeholder (or a
  database that cannot be found or read) have no score. **Vision at 427 px fills the
  gaps** on the photos being indexed, since it ranks almost the same way. A photo
  without a database score is neither left out nor favoured when the subset is chosen.
  Otherwise, on a profile like the second one, the subset would drift towards the years
  Photos happened to analyse.
- **Utility shots: from Vision's `isUtility`**, computed at indexing time on the chosen
  photos, then dropped and replaced. `ZISDETECTEDSCREENSHOT` can leave screenshots
  out of the whole library first, at no cost. The Utilities collections and the scene
  labels are not used.

## Decisions (2026-10-17)

Taken by Sergio on these numbers:

- **Drop the worst 10 %** by score: month by month when the subset is uniform in time,
  over the whole library otherwise, counted among the photos that have a score.
- **Photos without a database score** are neither dropped nor favoured when the subset is
  chosen. At indexing time Vision at 427 px scores them, mapped onto Photos' scale; below
  the threshold of their month they are dropped and refilled.
- **Utility shots: a false positive is better than a false negative.** `isUtility` at
  854 px on every indexed photo, plus the one at 427 px where Vision runs for the score;
  a photo is left out if either says so.
- **Screenshots** are left out of the whole library with `ZISDETECTEDSCREENSHOT`.
- **The tail disagreement is accepted.** It only touches photos without a database
  score, where Vision is better than nothing.

Still to measure while building the module: whether the image the index gets from
PhotoKit before the crop can feed Vision (the spike gave it the whole photo, not the
854×480 crop), and Vision on the i3 laptop, to see which derivatives a profile used every day
keeps locally.

## Measured while building the module (2026-10-18)

With `--probe-quality 2048` in Mosaic Companion, on the 1930 photographs of Sergio's index
that were also in this spike's corpus:

- **`isUtility` on the upright image indexing already decodes** (855 px across its crop,
  so 855×1140 for a portrait) disagrees with this spike's 854 px request on 6 of 1930
  photographs, 2 of 513 portraits. No extra request is needed for it.
- **The score at 427 px needs PhotoKit's own scaling.** Asked as this spike asked
  (`aspectFit`, 427 × 427), the scores are identical to the last bit, Spearman 0.964 with
  Photos. Asked as indexing asks (5 % more, then scaled down by the app, 428×321), 0.949;
  the large image scaled down by the app, 0.914. Vision tells the scaling apart.
- The synchronous `VNCalculateImageAestheticsScoresRequest` and the async request used here
  give the same numbers on all 2048.
- On the Intel iMac Vision does not scale with cores: about 230 ms a call with six at once,
  about 44 ms of wall time each, as one at a time.

On the i3 laptop (4 cores), the index's image was there for only 73 of 2048 photographs: on
a library that keeps originals in iCloud, a profile used every day has little at 854 px,
and most of its tiles come from derivatives of about 350 to 430 px. Vision took about
256 ms a call there, four at a time.

