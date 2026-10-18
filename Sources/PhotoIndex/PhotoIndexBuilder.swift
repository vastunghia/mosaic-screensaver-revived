import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos

/// How far a build has gone.
///
/// For a folder, `completed` of `total` are the photographs looked at, ready or
/// not. For a source filled to its target (`FillablePhotoSource`) the two are
/// `ready` of the target, since the photographs looked at have no fixed total:
/// every one passed over brings in another.
public struct IndexProgress: Equatable, Sendable {
    public var completed: Int
    public var reused: Int
    public var skipped: Int
    /// Not on this Mac, and not allowed to be fetched: see `PhotoSourceError.unavailable`.
    public var unavailable: Int
    /// Left out by Vision as a utility shot or a weak photograph, and
    /// replaced (evolution 4).
    public var rejected: Int
    public var total: Int
    /// Indexed and usable.
    public var ready: Int
    /// Of `ready`, those that can fill the screen; the others are tiles only.
    public var fullScreen: Int
    /// Filling to a target, and the library ran out of photographs that can be
    /// read here before reaching it — not merely smaller than the target.
    public var fellShort: Bool

    public init(
        completed: Int = 0, reused: Int = 0, skipped: Int = 0, unavailable: Int = 0, rejected: Int = 0, total: Int = 0,
        ready: Int = 0, fullScreen: Int? = nil, fellShort: Bool = false
    ) {
        self.completed = completed
        self.reused = reused
        self.skipped = skipped
        self.unavailable = unavailable
        self.rejected = rejected
        self.total = total
        self.ready = ready
        self.fullScreen = fullScreen ?? ready
        self.fellShort = fellShort
    }
}

/// M5: the "Creating photo database" of the original, done the way it should
/// have been done.
///
/// The original barred the way with a progress bar until it had read the whole
/// library. This one is **incremental**: it keeps what it already has, indexes
/// only what changed, saves its progress as it goes, and can be stopped and
/// resumed. Nothing here uses CoreImage — see `ImageSampling` for why the
/// averaging is done by hand instead.
public struct PhotoIndexBuilder: Sendable {
    /// 854x480, and the number is derived rather than chosen: the target grid of
    /// a cycle is sampled at `R · k` cells across the crop, and the largest those
    /// go is `R` = 120 with `k` = 4, which is 480 rows. A smaller thumbnail does
    /// not fail, which is the trouble: past its height each sub-cell averages
    /// less than a pixel, and the detail `k` = 4 exists to capture fades quietly
    /// towards a lower `k` at a threshold set by a storage constant.
    ///
    /// It was 640x360 while `R` topped out at 90. Measured on 2048 photographs,
    /// the index grew from 172 to 276 MB.
    public static let defaultThumbnailWidth = 854

    /// 4x4. The solver may only use its 1x1 reduction — that is the average
    /// colour of SPEC § 5 — but storing the finer grid costs sixteen floats and
    /// buys the freedom to try structural matching without reindexing, and the
    /// index is the one expensive artefact in the project.
    public static let defaultSignatureSide = 4

    public var thumbnailWidth: Int
    public var signatureSide: Int
    public var cropRule: CropRule
    /// See `defaultTileWidths`; only those narrower than `thumbnailWidth` count.
    public var tileWidths: [Int]
    /// What judges a photograph's looks once it is decoded, for a filled
    /// source that culls (`FillablePhotoSource.cull`): utility shots, and
    /// photographs Photos has not scored that fall below their month's bar,
    /// are left out and replaced. Nil judges nothing.
    public var assessor: (any PhotoAssessing)?

    /// How often progress is written down. Small enough that a crash loses
    /// seconds, large enough that the manifest is not rewritten per photograph.
    public var checkpointEvery: Int

    /// The longest a checkpoint waits when photographs are only found missing.
    /// A filled build on an optimised library asks for tens of thousands that
    /// are not here, in rounds of a few dozen, and the manifest lists them all:
    /// saving it after every batch wrote 2.1 GB in ten minutes (2026-10-12).
    public var checkpointInterval: TimeInterval = 30

    public init(
        thumbnailWidth: Int = PhotoIndexBuilder.defaultThumbnailWidth,
        signatureSide: Int = PhotoIndexBuilder.defaultSignatureSide,
        cropRule: CropRule = .standard,
        tileWidths: [Int] = PhotoIndexBuilder.defaultTileWidths,
        assessor: (any PhotoAssessing)? = nil,
        checkpointEvery: Int = 250
    ) {
        self.tileWidths = tileWidths
        self.assessor = assessor
        self.thumbnailWidth = thumbnailWidth
        self.signatureSide = signatureSide
        self.cropRule = cropRule
        self.checkpointEvery = checkpointEvery
    }

    /// How long a photograph found to be elsewhere is left out of a filled
    /// subset before it is asked for again (`IndexManifest.unavailableCheckedAt`).
    public static let unavailableRetryInterval: TimeInterval = 24 * 60 * 60

    /// Of a filled subset, the share guaranteed to fill the screen: a
    /// sixteenth, 128 of 2048, so the subjects come round again after 53
    /// minutes at 25 s a cycle (SPEC § 5). A quarter at first (2026-10-11);
    /// cut on 2026-10-12, because on an optimised library each one's sharp
    /// close-up has to be fetched from iCloud (`CloseUpShelf`), about 2 MB.
    public static let fullScreenShare = 16

    /// What a build prefers among the photographs that fill the screen: those
    /// whose close-up costs no download, because the shelf has it or this Mac
    /// has the photograph at `width` (SPEC § 5). With downloads allowed there
    /// is nothing to prefer, and none is passed.
    public struct CloseUpPreference: Sendable {
        public var width: Int
        /// Whether the shelf already holds this entry's close-up.
        public var isStocked: @Sendable (IndexEntry) -> Bool
        /// Photographs whose close-up was given up on too often
        /// (`DownloadLedger.resting(at:)`): tiles only for now, so that
        /// another subject takes their place.
        public var resting: Set<String>
        /// Whether the close-ups this Mac does not have are fetched: then the
        /// subjects are the rule's choice over the whole library, and one
        /// this Mac has too small is a tile until its close-up comes in.
        /// Otherwise only those this Mac has large enough are subjects, and
        /// on an optimised library they are not spread over time (2026-10-13:
        /// 12 a year from 2020 to 2022, none in 2025).
        public var fetches: Bool

        /// With close-ups fetched, the share of the target that should be at
        /// least `ringWidth` across, subjects counted: the tiles short of it
        /// are picked for a copy at that width (`IndexManifest.ringPicks`),
        /// which the shelf fetches after the subjects' close-ups. 0 picks none.
        public var ringShare: Double
        public var ringWidth: Int

        /// Chosen by Sergio on 2026-10-14 from specimens of the anchor's ring
        /// on his corpus (`--compare-ring --simulate-sharp`): with 8 % of the
        /// photographs sharp enough the ring was 4.1 delta E off what it was
        /// with any photograph, with 16 % 1.8. A copy costs about as much as a
        /// close-up, 1.05 MB on 2026-10-13: Photos fetches the same ~2048
        /// pixel derivative however little is asked for.
        public static let standardRingShare = 0.16
        /// `CloseUpOptions.standard.ringWidth`, which this module cannot see.
        public static let standardRingWidth = 640

        public init(
            width: Int, isStocked: @escaping @Sendable (IndexEntry) -> Bool, resting: Set<String> = [],
            fetches: Bool = false, ringShare: Double = 0, ringWidth: Int = Self.standardRingWidth
        ) {
            self.width = width
            self.isStocked = isStocked
            self.resting = resting
            self.fetches = fetches
            self.ringShare = ringShare
            self.ringWidth = ringWidth
        }
    }

    /// The narrower crops a photograph is asked at when it is not here at
    /// `thumbnailWidth`, widest first, down to the atlas's 256: a derivative
    /// that small still makes a tile (SPEC § 5).
    public static let defaultTileWidths = [640, 427, 256]

    /// Indexes `source` into `store`, keeping whatever is still good.
    ///
    /// A source filled to its target (`FillablePhotoSource`) is built in two
    /// phases of rounds. First the photographs that fill the screen, a
    /// sixteenth of the target, chosen among those not known to be short of
    /// it — and with `closeUps`, first among those whose close-up is here,
    /// looking at no more photographs than the target for them. Then the
    /// rest, chosen among all the others and taken at the largest size this Mac
    /// has, down to `tileWidths`: below `thumbnailWidth` they are tiles only.
    /// In each round the photographs found missing are left out and the choice
    /// made again; leaving photographs out never pushes out a chosen one, so
    /// every round only adds. Any other source is one round, as it always was.
    ///
    /// `availability` names what made a photograph unavailable — whether
    /// downloads were allowed — and `now` dates the check; both, and
    /// `closeUps`, are for a filled source only.
    @discardableResult
    public func build(
        from source: some PhotoSource,
        into store: PhotoIndexStore,
        root: String,
        availability: String = "",
        now: Date = Date(),
        preferring closeUps: CloseUpPreference? = nil,
        progress: (@Sendable (IndexProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> IndexManifest {
        let existing = try store.load()
        let checkpoints = Checkpoints(every: checkpointEvery, interval: checkpointInterval)
        var manifest: IndexManifest
        var known: [String: IndexEntry] = [:]
        var alreadySkipped: Set<String> = []

        if let existing, existing.matches(
            root: root, thumbnailWidth: thumbnailWidth, signatureSide: signatureSide, cropRule: cropRule
        ) {
            manifest = existing
            for entry in existing.entries { known[entry.id] = entry }
            alreadySkipped = Set(existing.skipped)
        } else {
            manifest = IndexManifest(
                root: root,
                thumbnailWidth: thumbnailWidth,
                thumbnailHeight: CanonicalAspect.height(forWidth: thumbnailWidth),
                signatureSide: signatureSide,
                cropRule: cropRule,
                entries: [],
                skipped: []
            )
        }

        guard let fillable = source as? any FillablePhotoSource else {
            let round = try self.round(
                over: try source.photos(), tier: .plain, from: source, into: store, manifest: &manifest,
                known: known, alreadySkipped: alreadySkipped, carry: [:], leftOut: LeftOut(), judge: nil,
                checkpoints: checkpoints,
                report: { kept, _, skipped, unavailable, short, total, reused in
                    progress?(IndexProgress(
                        completed: kept + skipped + unavailable + short, reused: reused, skipped: skipped,
                        unavailable: unavailable, total: total, ready: kept
                    ))
                },
                isCancelled: isCancelled
            )
            return try finish(&manifest, entries: round.kept, leftOut: LeftOut(
                skipped: Set(round.skipped), unavailable: Set(round.unavailable)
            ), store: store)
        }

        // What is known to be missing, left out of the choice. The broken stay
        // left out as long as they are remembered; the elsewhere and the short
        // until a day has passed or downloads were turned on or off, then all
        // are asked again — tiles included, which may have grown.
        let fresh = manifest.unavailableCheckedAt.map { now.timeIntervalSince($0) < Self.unavailableRetryInterval } ?? false
        let carried = fresh && manifest.unavailableContext == availability
        var leftOut = LeftOut(
            skipped: Set(manifest.skipped),
            unavailable: carried ? Set(manifest.unavailable) : [],
            belowFullScreen: carried
                ? Set(manifest.belowFullScreen).union(known.values.filter(isShort).map(\.id))
                : [],
            belowCloseUp: carried ? Set(manifest.belowCloseUp) : []
        )
        manifest.unavailableCheckedAt = carried ? manifest.unavailableCheckedAt : now
        manifest.unavailableContext = availability

        let target = fillable.target
        let fullScreenTarget = min(target, max(1, target / Self.fullScreenShare))
        // What is culled before anything is chosen (`Culling`); with an
        // assessor, the rest is judged by Vision once decoded. Without one,
        // the assessments an earlier build made are kept as they are.
        let whole = try fillable.library()
        let culling = fillable.cull(whole)
        let library = culling?.kept ?? whole
        let judge = culling.flatMap { culling in
            assessor.map { Judge(assessor: $0, culling: culling, book: AssessmentBook(manifest.assessments)) }
        }
        if let judge {
            // Those an earlier build left out are left out without a look.
            leftOut.rejected = Set(library.filter { judge.rejected($0) == true }.map(\.id.rawValue))
        }
        // What the index had: kept in every checkpoint until the build has
        // settled, so a reader never sees the index shrink while it runs.
        let previous = known.filter { id, entry in
            store.hasThumbnail(named: entry.thumbnail) && !leftOut.skipped.contains(id)
        }
        // Reused: what the index had before this build, never what an earlier
        // round of it read.
        let indexedBefore = Set(previous.keys)
        func reused(_ ids: some Collection<String>) -> Int { ids.filter(indexedBefore.contains).count }
        var cancelled = false

        // Phase A, first: the photographs that fill the screen and need no
        // download for their close-up. It reports nothing until it is done,
        // so the build says it has started: a window would otherwise show
        // the last count, still and complete, for as long as it takes.
        if closeUps != nil {
            progress?(IndexProgress(
                skipped: leftOut.skipped.count, unavailable: leftOut.unavailable.count, total: target
            ))
        }
        let resting = closeUps?.resting ?? []
        let previousSubjects = manifest.subjectsChoice == fillable.choice ? Set(manifest.subjects) : []
        let fetches = closeUps?.fetches == true
        let preferred = closeUps.flatMap { closeUps in fetches ? nil : closeUps }.map {
            self.preferred(
                count: fullScreenTarget, closeUps: $0, fillable: fillable, library: library, from: source,
                known: known, keeping: previousSubjects, leftOut: &leftOut, budget: target
            )
        } ?? []

        // Phase A: the photographs that fill the screen, the preferred first.
        var screen: [String: IndexEntry] = [:]
        var first: [String: IndexEntry] = [:]
        var pending: [PhotoDescriptor]? = preferred.isEmpty ? nil : preferred
        // Or, with close-ups fetched, the subjects whatever their size here,
        // but never one whose original is too narrow: no download makes it
        // fill the screen.
        let narrowOriginals = Set(library.compactMap { descriptor in
            descriptor.cropWidth.map { $0 < thumbnailWidth - 1 } == true ? descriptor.id.rawValue : nil
        })
        while fetches, !cancelled {
            let chosen = fillable.choose(
                from: library,
                excluding: leftOut.excluded.union(resting).union(narrowOriginals),
                count: fullScreenTarget
            )
            // A tile whose close-up came in is read again, to fill the screen.
            let promoting = Set(chosen.compactMap { descriptor -> String? in
                guard let entry = known[descriptor.id.rawValue], !entry.canFillScreen,
                      entry.versionToken == descriptor.versionToken, closeUps?.isStocked(entry) == true else {
                    return nil
                }
                return entry.id
            })
            let round = try self.round(
                over: chosen, tier: .any(belowFullScreen: leftOut.belowFullScreen, promoting: promoting),
                from: source, into: store, manifest: &manifest, known: known, alreadySkipped: alreadySkipped,
                carry: previous, leftOut: leftOut, judge: judge, indexedBefore: indexedBefore, checkpoints: checkpoints,
                report: { ready, readyFullScreen, skipped, unavailable, _, _, reusedHere in
                    progress?(IndexProgress(
                        completed: ready, reused: reusedHere,
                        skipped: leftOut.skipped.count + skipped,
                        unavailable: leftOut.unavailable.count + unavailable,
                        total: target, ready: ready, fullScreen: readyFullScreen
                    ))
                },
                isCancelled: isCancelled
            )
            screen = round.kept
            for (id, entry) in round.kept { known[id] = entry }
            leftOut.skipped.formUnion(round.skipped)
            leftOut.unavailable.formUnion(round.unavailable)
            leftOut.rejected.formUnion(round.rejected)
            for entry in round.kept.values {
                if isShort(entry) {
                    leftOut.belowFullScreen.insert(entry.id)
                } else {
                    leftOut.belowFullScreen.remove(entry.id)
                }
            }
            cancelled = round.cancelled
            if round.skipped.isEmpty && round.unavailable.isEmpty && round.rejected.isEmpty { break }
        }
        while !fetches, !cancelled {
            let chosen = pending ?? fillable.choose(
                from: library,
                excluding: leftOut.excluded.union(leftOut.belowFullScreen).union(first.keys).union(resting),
                count: fullScreenTarget - first.count
            )
            let isPreferred = pending != nil
            pending = nil
            let before = first
            let round = try self.round(
                over: chosen, tier: .fullScreen, from: source, into: store, manifest: &manifest,
                known: known, alreadySkipped: alreadySkipped, carry: previous.merging(before) { _, new in new },
                leftOut: leftOut, judge: judge, indexedBefore: indexedBefore, checkpoints: checkpoints,
                report: { ready, _, skipped, unavailable, _, _, reusedHere in
                    progress?(IndexProgress(
                        completed: before.count + ready, reused: reused(before.keys) + reusedHere,
                        skipped: leftOut.skipped.count + skipped,
                        unavailable: leftOut.unavailable.count + unavailable,
                        total: target, ready: before.count + ready, fullScreen: before.count + ready
                    ))
                },
                isCancelled: isCancelled
            )
            screen = before.merging(round.kept) { first, _ in first }
            for (id, entry) in round.kept { known[id] = entry }
            leftOut.skipped.formUnion(round.skipped)
            leftOut.belowFullScreen.formUnion(round.short)
            leftOut.rejected.formUnion(round.rejected)
            cancelled = round.cancelled
            if isPreferred {
                first = screen
                if first.count < fullScreenTarget { continue }
                break
            }
            if round.skipped.isEmpty && round.short.isEmpty && round.rejected.isEmpty { break }
        }

        if closeUps != nil {
            manifest.subjects = screen.keys.sorted()
            manifest.subjectsChoice = fillable.choice
        } else {
            manifest.subjects = []
            manifest.subjectsChoice = nil
        }

        // Phase B: the rest, as large as this Mac has them. With close-ups
        // fetched, only the subjects' close-ups are fetched: a tile fills the
        // screen once the shelf could make its close-up from what is here.
        let tileFillsScreen: (@Sendable (IndexEntry) -> Bool)? = fetches ? closeUps?.isStocked : nil
        var tiles: [String: IndexEntry] = [:]
        var fellShort = false
        var total = target
        while !cancelled {
            let count = target - screen.count
            let chosen = fillable.choose(
                from: library, excluding: leftOut.excluded.union(screen.keys),
                count: count
            )
            // Short because photographs were left out, not because the
            // library or the albums are smaller than the target.
            fellShort = chosen.count < count && !leftOut.isEmpty
            total = screen.count + min(count, chosen.count)
            let carry = previous.merging(screen) { _, new in new }
            let round = try self.round(
                over: chosen, tier: .any(belowFullScreen: leftOut.belowFullScreen.union(resting), fillsScreen: tileFillsScreen),
                from: source, into: store, manifest: &manifest, known: known, alreadySkipped: alreadySkipped, carry: carry, leftOut: leftOut,
                judge: judge, indexedBefore: indexedBefore, checkpoints: checkpoints,
                report: { ready, readyFullScreen, skipped, unavailable, _, _, reusedHere in
                    progress?(IndexProgress(
                        completed: screen.count + ready, reused: reused(screen.keys) + reusedHere,
                        skipped: leftOut.skipped.count + skipped,
                        unavailable: leftOut.unavailable.count + unavailable,
                        total: total, ready: screen.count + ready, fullScreen: screen.count + readyFullScreen
                    ))
                },
                isCancelled: isCancelled
            )
            tiles = round.kept
            for (id, entry) in round.kept { known[id] = entry }
            leftOut.skipped.formUnion(round.skipped)
            leftOut.unavailable.formUnion(round.unavailable)
            leftOut.rejected.formUnion(round.rejected)
            leftOut.belowFullScreen.formUnion(round.kept.values.filter(isShort).map(\.id))
            cancelled = round.cancelled
            if round.skipped.isEmpty && round.unavailable.isEmpty && round.rejected.isEmpty || cancelled { break }
        }

        // Stopped half way, nothing is thrown away: what the index had stays,
        // with what this build added, and the next one settles it.
        var entries = screen.merging(tiles) { first, _ in first }
        if cancelled { entries = previous.merging(entries) { _, new in new } }
        if fetches, !cancelled, let closeUps, closeUps.ringShare > 0 {
            manifest.ringPicks = try sharpenRing(
                &entries, picked: manifest.ringPicks, preference: closeUps, target: target, library: library,
                fillable: fillable, subjects: Set(manifest.subjects), resting: resting, from: source, into: store
            )
        } else if !cancelled {
            manifest.ringPicks = []
        }
        if let judge {
            manifest.assessments = judge.book.assessments(of: Set(whole.map(\.id.rawValue)))
        }
        progress?(IndexProgress(
            completed: entries.count, reused: reused(entries.keys), skipped: leftOut.skipped.count,
            unavailable: leftOut.unavailable.count, rejected: leftOut.rejected.count,
            total: cancelled ? target : total, ready: entries.count,
            fullScreen: entries.values.filter(\.canFillScreen).count, fellShort: fellShort
        ))
        return try finish(&manifest, entries: entries, leftOut: leftOut, store: store)
    }

    /// Phase C, with close-ups fetched: the tiles the anchor's ring wants at
    /// `ringWidth` (SPEC § 5). Those picked before whose copy has come in are
    /// read again at that width, without the network, and stay tiles. Then as
    /// many more are picked, in the rule's order among the tiles too narrow,
    /// as bring `ringShare` of the target to that width, the subjects counted
    /// as there: their close-up brings it. Those picked before come first, so
    /// that nothing fetched is fetched for nothing.
    private func sharpenRing(
        _ entries: inout [String: IndexEntry], picked: [String], preference: CloseUpPreference, target: Int,
        library: [PhotoDescriptor], fillable: any FillablePhotoSource, subjects: Set<String>, resting: Set<String>,
        from source: some PhotoSource, into store: PhotoIndexStore
    ) throws -> [String] {
        let width = preference.ringWidth
        let narrowest = width - 1
        func isSharp(_ entry: IndexEntry) -> Bool { entry.pixelWidth >= narrowest }

        let due = picked.compactMap { entries[$0] }.filter { !isSharp($0) && !$0.canFillScreen }
        if !due.isEmpty {
            let read = Sharpened()
            let side = signatureSide
            let rule = cropRule
            DispatchQueue.concurrentPerform(iterations: due.count) { offset in
                let entry = due[offset]
                // Not here yet, or not readable now: as it was.
                guard let (image, cropStart) = try? Self.canonicalImage(
                    of: entry.photoID, from: source, width: width, rule: rule
                ), image.width >= narrowest,
                    let signature = try? ImageSampling.signature(of: image, side: side),
                    (try? store.writeThumbnail(image, named: entry.thumbnail)) != nil else { return }
                read.add(IndexEntry(
                    id: entry.id, versionToken: entry.versionToken, thumbnail: entry.thumbnail,
                    signature: signature, pixelWidth: image.width, pixelHeight: image.height,
                    cropStart: cropStart, tileOnly: true
                ))
            }
            for entry in read.entries { entries[entry.id] = entry }
        }

        let ringTarget = Int((Double(target) * preference.ringShare).rounded())
        let sharp = Set(entries.values.filter(isSharp).map(\.id)).union(subjects)
        let needed = ringTarget - sharp.count
        guard needed > 0 else { return [] }
        // A narrow original stays narrow whatever is fetched.
        let eligible = library.filter { descriptor in
            let id = descriptor.id.rawValue
            guard let entry = entries[id], !sharp.contains(id), !entry.canFillScreen, !resting.contains(id),
                  entry.versionToken == descriptor.versionToken else { return false }
            return descriptor.cropWidth.map { $0 >= narrowest } ?? true
        }
        let eligibleIDs = Set(eligible.map(\.id.rawValue))
        let kept = Array(picked.filter(eligibleIDs.contains).prefix(needed))
        let more = fillable.choose(from: eligible, excluding: Set(kept), count: needed - kept.count)
        return kept + more.map(\.id.rawValue)
    }

    /// The photographs that fill the screen whose close-up this Mac has: the
    /// rule's choice of `count` among the library less those known not to,
    /// in rounds like the others. A photograph already indexed whose close-up
    /// the shelf holds is taken without asking; any other is asked for at the
    /// close-up's width, without the network, and one that is not there is
    /// left out of the next round.
    ///
    /// On an optimised library few are, and the rule would walk through all
    /// of it — 57,000 photographs, minutes. So it asks for no more than
    /// `budget` in a day, counting those already found missing, and stops
    /// with fewer: the rest of the subjects are then chosen as before.
    ///
    /// The subjects of the last build under the same choice, `previous`,
    /// come before all that: a build after the shelf fetched (the library
    /// changes with every fetch) keeps what it fetched for, and asks for
    /// nothing.
    private func preferred(
        count: Int, closeUps: CloseUpPreference, fillable: any FillablePhotoSource, library: [PhotoDescriptor],
        from source: some PhotoSource, known: [String: IndexEntry], keeping previous: Set<String>,
        leftOut: inout LeftOut, budget: Int
    ) -> [PhotoDescriptor] {
        func isStocked(_ descriptor: PhotoDescriptor) -> Bool {
            guard let entry = known[descriptor.id.rawValue] else { return false }
            return entry.versionToken == descriptor.versionToken && entry.canFillScreen && closeUps.isStocked(entry)
        }
        // A close-up found missing and fetched since is here now, though the
        // day's list still says otherwise.
        let stocked = library.filter(isStocked)
        leftOut.belowCloseUp.subtract(stocked.map(\.id.rawValue))
        let left = leftOut.excluded.union(leftOut.belowFullScreen).union(closeUps.resting)
        // The last build's subjects first, whether their close-up came in or
        // not: one not yet fetched is asked for again, until it rests.
        let kept = previous.isEmpty ? [] : fillable.choose(
            from: library.filter { previous.contains($0.id.rawValue) }, excluding: left, count: count
        )
        if kept.count == count { return kept }
        // Then, enough of them, the rule's choice among the close-ups here.
        let excluded = left.union(kept.map(\.id.rawValue))
        let count = count - kept.count
        let ready = fillable.choose(from: stocked, excluding: excluded, count: count)
        if ready.count == count { return kept + ready }

        var found: [PhotoDescriptor] = []
        // Asked once and found here: not asked again in the rounds after.
        // Each round replaces the photographs found missing, and asking the
        // rest again cost a 1920 px decode each: on an optimised library a
        // round per missing photograph, 386 of them, took 13 minutes
        // (2026-10-18, an optimised profile).
        var confirmed: Set<String> = []
        while true {
            let chosen = fillable.choose(
                from: library,
                excluding: excluded.union(leftOut.belowCloseUp),
                count: count
            )
            var here: Set<String> = []
            var unknown: [PhotoDescriptor] = []
            for descriptor in chosen {
                if isStocked(descriptor) || confirmed.contains(descriptor.id.rawValue) {
                    here.insert(descriptor.id.rawValue)
                } else {
                    unknown.append(descriptor)
                }
            }
            let asking = Array(unknown.prefix(max(0, budget - leftOut.belowCloseUp.count)))
            let missing = Missing()
            DispatchQueue.concurrentPerform(iterations: asking.count) { offset in
                let id = asking[offset].id
                do {
                    _ = try source.uprightImage(for: id, cropWidth: closeUps.width)
                } catch {
                    // Elsewhere or broken, it makes no close-up here.
                    missing.insert(id.rawValue)
                }
            }
            let short = missing.ids
            let arrived = asking.map(\.id.rawValue).filter { !short.contains($0) }
            here.formUnion(arrived)
            confirmed.formUnion(arrived)
            leftOut.belowCloseUp.formUnion(short)
            found = chosen.filter { here.contains($0.id.rawValue) }
            // Done when every one chosen was here, or nothing more may be asked.
            if short.isEmpty || asking.count < unknown.count { return kept + found }
        }
    }

    /// What a filled build leaves out of the choice, by reason.
    private struct LeftOut {
        var skipped: Set<String> = []
        var unavailable: Set<String> = []
        var belowFullScreen: Set<String> = []
        /// Not here at the close-up's width: left out of the preferred
        /// subjects only (`preferred`).
        var belowCloseUp: Set<String> = []
        /// Left out by Vision (`Judge`); not written down, but found again
        /// from the assessments by the next build.
        var rejected: Set<String> = []

        var isEmpty: Bool { skipped.isEmpty && unavailable.isEmpty && rejected.isEmpty }

        /// Never chosen again in this build, whatever the role.
        var excluded: Set<String> { skipped.union(unavailable).union(rejected) }
    }

    /// What a round asks of each photograph.
    private enum Tier {
        /// At `thumbnailWidth` only, as a folder always was: not there is
        /// unavailable.
        case plain
        /// At `thumbnailWidth` only, for the photographs that fill the screen:
        /// not there is short, and a tile already indexed is asked again.
        case fullScreen
        /// At `thumbnailWidth`, then down `tileWidths`; a photograph known to
        /// be short starts below. Not there even at the last is unavailable.
        /// A tile in `promoting` is asked again from the top: a subject whose
        /// close-up came in from iCloud, which left this Mac a derivative
        /// large enough to fill the screen. With `fillsScreen`, one read at
        /// `thumbnailWidth` fills the screen only if it says so: with
        /// close-ups fetched, a tile that is not a subject only once the shelf
        /// made its close-up here, or the shelf would fetch one for every tile
        /// this Mac has that large (2026-10-15: 211 instead of 128 on an
        /// optimised profile).
        case any(
            belowFullScreen: Set<String>, promoting: Set<String> = [],
            fillsScreen: (@Sendable (IndexEntry) -> Bool)? = nil
        )
    }

    private struct Round {
        var kept: [String: IndexEntry]
        var skipped: [String]
        var unavailable: [String]
        var short: [String]
        var rejected: [String]
        var cancelled: Bool
    }

    /// One pass over `descriptors`: what is still good is kept, the rest read
    /// on every core, a checkpoint saved every `checkpointEvery`. `carry` and
    /// `leftOut` are what earlier work found, written into every checkpoint so
    /// a manifest on disk never forgets it.
    private func round(
        over descriptors: [PhotoDescriptor],
        tier: Tier,
        from source: some PhotoSource,
        into store: PhotoIndexStore,
        manifest: inout IndexManifest,
        known: [String: IndexEntry],
        alreadySkipped: Set<String>,
        carry: [String: IndexEntry],
        leftOut: LeftOut,
        judge: Judge?,
        indexedBefore: Set<String>? = nil,
        checkpoints: Checkpoints,
        report: (
            _ kept: Int, _ keptFullScreen: Int, _ skipped: Int, _ unavailable: Int, _ short: Int,
            _ total: Int, _ reused: Int
        ) -> Void,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> Round {
        // What is still good, and what has to be read.
        var kept: [String: IndexEntry] = [:]
        var outstanding: [PhotoDescriptor] = []
        var skipped: [String] = []
        var unavailable: [String] = []
        var short: [String] = []
        var rejected: [String] = []

        // Filling the screen takes `thumbnailWidth` across, from an original as
        // from a derivative: a 350 px original shown full screen is as soft as
        // a 350 px derivative (2026-10-11, 27 of them on an optimised library).
        // A folder is indexed as it always was.
        let tiered: Bool = if case .plain = tier { false } else { true }
        let narrowest = thumbnailWidth - 1
        let narrow: @Sendable (Int) -> Bool = { crop in tiered && crop < narrowest }
        let fillsScreen = Self.fillsScreen(in: tier)
        // One read at `thumbnailWidth` takes the role this round gives it,
        // without being read again.
        let settle: @Sendable (IndexEntry) -> IndexEntry = { entry in
            tiered && entry.pixelWidth >= narrowest ? entry.role(tileOnly: !fillsScreen(entry)) : entry
        }

        for descriptor in descriptors {
            let id = descriptor.id.rawValue
            // Judged already: left out without being read, or kept only once
            // judged under the current revision.
            let verdict = judge?.rejected(descriptor)
            if verdict == true {
                rejected.append(id)
                continue
            }
            let settled = known[id].map(settle)
            if judge == nil || verdict != nil, let entry = settled,
               entry.versionToken == descriptor.versionToken,
               store.hasThumbnail(named: entry.thumbnail),
               // Indexed before narrow originals were tiles: read again, to be
               // marked as one.
               !(entry.canFillScreen && narrow(entry.pixelWidth)),
               entry.canFillScreen || !Self.isFullScreen(tier),
               // Resting from the subjects: read again, to be a tile.
               !(entry.canFillScreen && Self.isBelowFullScreen(id, in: tier)),
               !(!entry.canFillScreen && Self.isPromoting(id, in: tier)) {
                kept[id] = entry
            } else if alreadySkipped.contains(id), known[id] == nil {
                // Known bad and unchanged: not worth another failed decode.
                skipped.append(id)
            } else {
                outstanding.append(descriptor)
            }
        }

        func tally() -> Int { kept.values.filter(\.canFillScreen).count }
        let reused = indexedBefore.map { before in kept.keys.filter(before.contains).count } ?? kept.count
        report(kept.count, tally(), skipped.count, unavailable.count, short.count, descriptors.count, reused)

        let collector = Collector()
        let width = thumbnailWidth
        let side = signatureSide
        let rule = cropRule
        let tileWidths = self.tileWidths.filter { $0 < width }.sorted(by: >)
        var cancelled = false

        for batch in stride(from: 0, to: outstanding.count, by: checkpointEvery) {
            if isCancelled?() == true {
                cancelled = true
                break
            }
            let slice = Array(outstanding[batch..<min(batch + checkpointEvery, outstanding.count)])

            // Decoding is the whole cost and the photographs are independent, so
            // it runs on every core. The collector is the only shared state.
            DispatchQueue.concurrentPerform(iterations: slice.count) { offset in
                let descriptor = slice[offset]
                let id = descriptor.id.rawValue
                let widths: [Int] = switch tier {
                case .plain, .fullScreen: [width]
                case .any(let below, let promoting, _):
                    (below.contains(id) && !promoting.contains(id) ? [] : [width]) + tileWidths
                }
                do {
                    for asked in widths {
                        let image: CGImage
                        let cropStart: Double?
                        do {
                            (image, cropStart) = try Self.canonicalImage(
                                of: descriptor.id, from: source, width: asked, rule: rule,
                                inspect: judge.map { judge in
                                    { upright in
                                        // Too narrow to fill the screen, it is short
                                        // here whatever Vision says: judged if it
                                        // comes back as a tile. On an optimised
                                        // library 1190 small originals were judged
                                        // for nothing (2026-10-18, an Intel laptop).
                                        let crop = Int(CanonicalCrop.rect(width: upright.width, height: upright.height).width)
                                        if case .fullScreen = tier, narrow(crop) { return }
                                        try judge.inspect(upright, of: descriptor, from: source)
                                    }
                                }
                            )
                        } catch PhotoSourceError.unavailable {
                            continue
                        }
                        if case .fullScreen = tier, narrow(image.width) {
                            collector.short(id)
                            return
                        }
                        let signature = try ImageSampling.signature(of: image, side: side)
                        let name = IndexEntry.thumbnailName(id: id, versionToken: descriptor.versionToken)
                        try store.writeThumbnail(image, named: name)
                        let entry = IndexEntry(
                            id: id,
                            versionToken: descriptor.versionToken,
                            thumbnail: name,
                            signature: signature,
                            pixelWidth: image.width,
                            pixelHeight: image.height,
                            cropStart: cropStart,
                            tileOnly: asked < width || narrow(image.width)
                        )
                        collector.add(settle(entry))
                        return
                    }
                    // Not broken, only elsewhere: counted, and asked for again
                    // next time.
                    if case .fullScreen = tier { collector.short(id) } else { collector.unavailable(id) }
                } catch is Judge.Rejection {
                    collector.reject(id)
                } catch {
                    // A folder of three thousand files that dies on the corrupt
                    // one is unusable. A failure is a recorded skip.
                    collector.skip(id)
                }
            }

            let drained = collector.drain()
            for entry in drained.entries { kept[entry.id] = entry }
            skipped.append(contentsOf: drained.failures)
            unavailable.append(contentsOf: drained.elsewhere)
            short.append(contentsOf: drained.short)
            rejected.append(contentsOf: drained.rejected)
            report(kept.count, tally(), skipped.count, unavailable.count, short.count, descriptors.count, reused)

            guard checkpoints.isDue(adding: drained.entries.count) else { continue }
            // The thumbnail is on disk before the manifest names it, so a
            // checkpoint never promises pixels that are not there.
            manifest.entries = Array(carry.merging(kept) { _, new in new }.values)
            manifest.skipped = Array(leftOut.skipped.union(skipped))
            manifest.unavailable = Array(leftOut.unavailable.union(unavailable))
            manifest.belowFullScreen = Array(leftOut.belowFullScreen.union(short).union(
                kept.values.filter(isShort).map(\.id)
            ))
            manifest.belowCloseUp = Array(leftOut.belowCloseUp)
            if let judge { manifest.assessments = judge.book.assessments() }
            try store.save(manifest)
        }
        if isCancelled?() == true { cancelled = true }
        return Round(
            kept: kept, skipped: skipped, unavailable: unavailable, short: short, rejected: rejected, cancelled: cancelled
        )
    }

    private static func isFullScreen(_ tier: Tier) -> Bool {
        if case .fullScreen = tier { return true }
        return false
    }

    /// Not here at `thumbnailWidth`, or narrower than the screen: a tile for
    /// lack of pixels, not one that only its role keeps from the screen.
    private func isShort(_ entry: IndexEntry) -> Bool {
        !entry.canFillScreen && entry.pixelWidth < thumbnailWidth - 1
    }

    private static func fillsScreen(in tier: Tier) -> @Sendable (IndexEntry) -> Bool {
        if case .any(_, _, let fillsScreen?) = tier { return fillsScreen }
        return { _ in true }
    }

    private static func isBelowFullScreen(_ id: String, in tier: Tier) -> Bool {
        if case .any(let below, _, _) = tier { return below.contains(id) }
        return false
    }

    private static func isPromoting(_ id: String, in tier: Tier) -> Bool {
        if case .any(_, let promoting, _) = tier { return promoting.contains(id) }
        return false
    }

    private func finish(
        _ manifest: inout IndexManifest, entries: [String: IndexEntry], leftOut: LeftOut, store: PhotoIndexStore
    ) throws -> IndexManifest {
        manifest.entries = entries.values.sorted { $0.id < $1.id }
        manifest.skipped = leftOut.skipped.sorted()
        manifest.unavailable = leftOut.unavailable.sorted()
        manifest.belowFullScreen = leftOut.belowFullScreen.sorted()
        manifest.belowCloseUp = leftOut.belowCloseUp.sorted()
        try store.save(manifest)

        // Only once the manifest is the truth on disk.
        _ = try? store.collectOrphans(keeping: Set(manifest.entries.map(\.thumbnail)))

        return manifest
    }

    /// Decoded once, whole: faces are looked for in the upright photograph and
    /// the crop is cut from the same pixels, so the face-aware crop costs Vision
    /// (~40 ms a photograph at 854 px, measured 2026-10-02) and no second decode.
    ///
    /// `inspect` sees the whole photograph first, and may throw to stop
    /// there: Vision judges it before faces are looked for. With the centred
    /// crop there is no whole photograph, and it sees the crop.
    static func canonicalImage(
        of id: PhotoID, from source: some PhotoSource, width: Int, rule: CropRule,
        inspect: ((CGImage) throws -> Void)? = nil
    ) throws -> (CGImage, cropStart: Double?) {
        switch rule {
        case .centre:
            let image = try source.canonicalImage(for: id, maxPixelWidth: width)
            try inspect?(image)
            return (image, nil)
        case .faces:
            let upright = try source.uprightImage(for: id, cropWidth: width)
            try inspect?(upright)
            // A photograph Vision cannot read is still a photograph: it keeps
            // the centre, as one without faces does.
            let faces = (try? FaceDetector.faces(in: upright)) ?? []
            let choice = FaceAwareCrop.choose(
                width: upright.width, height: upright.height, faces: faces.map(\.rect)
            )
            let start = CanonicalCrop.start(of: choice.rect, width: upright.width, height: upright.height)
            let window = CanonicalCrop.rect(width: upright.width, height: upright.height, start: start)
            do {
                return (try CanonicalCrop.image(upright, cropping: window, maxPixelWidth: width), start)
            } catch {
                throw PhotoSourceError.couldNotRender(id)
            }
        }
    }
}

/// When a build writes its manifest down: once `every` photographs have
/// been indexed since the last time, or `interval` has passed.
private final class Checkpoints {
    private let every: Int
    private let interval: TimeInterval
    private var added = 0
    private var last = Date()

    init(every: Int, interval: TimeInterval) {
        self.every = every
        self.interval = interval
    }

    func isDue(adding count: Int) -> Bool {
        added += count
        guard added >= every || Date().timeIntervalSince(last) >= interval else { return false }
        added = 0
        last = Date()
        return true
    }
}

/// The photographs `preferred` found without a close-up, from every core.
private final class Missing: @unchecked Sendable {
    private let lock = NSLock()
    private var found: Set<String> = []

    func insert(_ id: String) {
        lock.lock(); found.insert(id); lock.unlock()
    }

    var ids: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return found
    }
}

/// The one piece of shared state in a concurrent build.
/// Tiles read again for the ring, from every core at once.
private final class Sharpened: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [IndexEntry] = []

    func add(_ entry: IndexEntry) {
        lock.lock(); read.append(entry); lock.unlock()
    }

    var entries: [IndexEntry] {
        lock.lock(); defer { lock.unlock() }
        return read
    }
}

private final class Collector: @unchecked Sendable {
    struct Drained {
        var entries: [IndexEntry] = []
        var failures: [String] = []
        var elsewhere: [String] = []
        var short: [String] = []
        var rejected: [String] = []
    }

    private let lock = NSLock()
    private var current = Drained()

    func add(_ entry: IndexEntry) {
        lock.lock(); defer { lock.unlock() }
        current.entries.append(entry)
    }

    func skip(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        current.failures.append(id)
    }

    func unavailable(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        current.elsewhere.append(id)
    }

    func short(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        current.short.append(id)
    }

    func reject(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        current.rejected.append(id)
    }

    func drain() -> Drained {
        lock.lock(); defer { lock.unlock() }
        defer { current = Drained() }
        return current
    }
}
