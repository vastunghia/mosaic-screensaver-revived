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
    public var total: Int
    /// Indexed and usable.
    public var ready: Int
    /// Filling to a target, and the library ran out of photographs that can be
    /// read here before reaching it — not merely smaller than the target.
    public var fellShort: Bool

    public init(
        completed: Int = 0, reused: Int = 0, skipped: Int = 0, unavailable: Int = 0, total: Int = 0,
        ready: Int = 0, fellShort: Bool = false
    ) {
        self.completed = completed
        self.reused = reused
        self.skipped = skipped
        self.unavailable = unavailable
        self.total = total
        self.ready = ready
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

    /// How often progress is written down. Small enough that a crash loses
    /// seconds, large enough that the manifest is not rewritten per photograph.
    public var checkpointEvery: Int

    public init(
        thumbnailWidth: Int = PhotoIndexBuilder.defaultThumbnailWidth,
        signatureSide: Int = PhotoIndexBuilder.defaultSignatureSide,
        cropRule: CropRule = .standard,
        checkpointEvery: Int = 250
    ) {
        self.thumbnailWidth = thumbnailWidth
        self.signatureSide = signatureSide
        self.cropRule = cropRule
        self.checkpointEvery = checkpointEvery
    }

    /// How long a photograph found to be elsewhere is left out of a filled
    /// subset before it is asked for again (`IndexManifest.unavailableCheckedAt`).
    public static let unavailableRetryInterval: TimeInterval = 24 * 60 * 60

    /// Indexes `source` into `store`, keeping whatever is still good.
    ///
    /// A source filled to its target (`FillablePhotoSource`) is built in
    /// rounds: the photographs that turn out to be elsewhere or broken are
    /// left out, the choice is made again, and the newcomers are read, until a
    /// round brings in nothing missing or the library has no more. Leaving
    /// photographs out never pushes out a chosen one, so every round only adds.
    /// Any other source is one round, as it always was.
    ///
    /// `availability` names what made a photograph unavailable — whether
    /// downloads were allowed — and `now` dates the check; both are for a
    /// filled source only.
    @discardableResult
    public func build(
        from source: some PhotoSource,
        into store: PhotoIndexStore,
        root: String,
        availability: String = "",
        now: Date = Date(),
        progress: (@Sendable (IndexProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> IndexManifest {
        let existing = try store.load()
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
                over: try source.photos(), from: source, into: store, manifest: &manifest,
                known: known, alreadySkipped: alreadySkipped, leftOut: ([], []),
                report: { kept, skipped, unavailable, total, reused in
                    progress?(IndexProgress(
                        completed: kept + skipped + unavailable, reused: reused, skipped: skipped,
                        unavailable: unavailable, total: total, ready: kept
                    ))
                },
                isCancelled: isCancelled
            )
            return try finish(&manifest, kept: round.kept, skipped: round.skipped,
                              unavailable: round.unavailable, store: store)
        }

        // What is known to be missing, left out of the choice. The broken stay
        // left out as long as they are remembered; the elsewhere until a day has
        // passed or downloads were turned on or off, then all are asked again.
        let fresh = manifest.unavailableCheckedAt.map { now.timeIntervalSince($0) < Self.unavailableRetryInterval } ?? false
        let carried = fresh && manifest.unavailableContext == availability
        var skipped = Set(manifest.skipped)
        var elsewhere = carried ? Set(manifest.unavailable) : []
        manifest.unavailableCheckedAt = carried ? manifest.unavailableCheckedAt : now
        manifest.unavailableContext = availability

        let target = fillable.target
        let library = try fillable.library()
        // What the index had already, of the first choice: the later rounds'
        // reuse is their own earlier work.
        var reused: Int?
        var kept: [String: IndexEntry] = [:]
        var fellShort = false
        var total = target
        while true {
            let chosen = fillable.choose(from: library, excluding: skipped.union(elsewhere))
            // Short because photographs were left out, not because the
            // library or the albums are smaller than the target.
            fellShort = chosen.count < target && !(skipped.isEmpty && elsewhere.isEmpty)
            total = min(target, chosen.count)
            let round = try self.round(
                over: chosen, from: source, into: store, manifest: &manifest,
                known: known, alreadySkipped: alreadySkipped,
                leftOut: (skipped, elsewhere),
                report: { ready, newlySkipped, newlyElsewhere, _, reusedHere in
                    if reused == nil { reused = reusedHere }
                    progress?(IndexProgress(
                        completed: ready, reused: reused ?? 0,
                        skipped: skipped.count + newlySkipped, unavailable: elsewhere.count + newlyElsewhere,
                        total: min(target, chosen.count), ready: ready, fellShort: false
                    ))
                },
                isCancelled: isCancelled
            )
            kept = round.kept
            for (id, entry) in round.kept { known[id] = entry }
            let missing = round.skipped.count + round.unavailable.count
            skipped.formUnion(round.skipped)
            elsewhere.formUnion(round.unavailable)
            if missing == 0 || round.cancelled { break }
        }
        progress?(IndexProgress(
            completed: kept.count, reused: reused ?? 0, skipped: skipped.count,
            unavailable: elsewhere.count, total: total, ready: kept.count,
            fellShort: fellShort
        ))
        return try finish(&manifest, kept: kept, skipped: Array(skipped), unavailable: Array(elsewhere), store: store)
    }

    private struct Round {
        var kept: [String: IndexEntry]
        var skipped: [String]
        var unavailable: [String]
        var cancelled: Bool
    }

    /// One pass over `descriptors`: what is still good is kept, the rest read
    /// on every core, a checkpoint saved every `checkpointEvery`. `leftOut` is
    /// what earlier rounds found missing, written into every checkpoint so a
    /// manifest on disk never forgets it.
    private func round(
        over descriptors: [PhotoDescriptor],
        from source: some PhotoSource,
        into store: PhotoIndexStore,
        manifest: inout IndexManifest,
        known: [String: IndexEntry],
        alreadySkipped: Set<String>,
        leftOut: (skipped: Set<String>, unavailable: Set<String>),
        report: (_ kept: Int, _ skipped: Int, _ unavailable: Int, _ total: Int, _ reused: Int) -> Void,
        isCancelled: (@Sendable () -> Bool)?
    ) throws -> Round {
        // What is still good, and what has to be read.
        var kept: [String: IndexEntry] = [:]
        var outstanding: [PhotoDescriptor] = []
        var skipped: [String] = []
        var unavailable: [String] = []

        for descriptor in descriptors {
            let id = descriptor.id.rawValue
            if let entry = known[id],
               entry.versionToken == descriptor.versionToken,
               store.hasThumbnail(named: entry.thumbnail) {
                kept[id] = entry
            } else if alreadySkipped.contains(id), known[id] == nil {
                // Known bad and unchanged: not worth another failed decode.
                skipped.append(id)
            } else {
                outstanding.append(descriptor)
            }
        }

        let reused = kept.count
        report(kept.count, skipped.count, unavailable.count, descriptors.count, reused)

        let collector = Collector()
        let width = thumbnailWidth
        let side = signatureSide
        let rule = cropRule
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
                do {
                    let (image, cropStart) = try Self.canonicalImage(
                        of: descriptor.id, from: source, width: width, rule: rule
                    )
                    let signature = try ImageSampling.signature(of: image, side: side)
                    let name = IndexEntry.thumbnailName(id: id, versionToken: descriptor.versionToken)
                    try store.writeThumbnail(image, named: name)
                    collector.add(IndexEntry(
                        id: id,
                        versionToken: descriptor.versionToken,
                        thumbnail: name,
                        signature: signature,
                        pixelWidth: image.width,
                        pixelHeight: image.height,
                        cropStart: cropStart
                    ))
                } catch PhotoSourceError.unavailable {
                    // Not broken, only elsewhere: counted, and asked for again
                    // next time.
                    collector.unavailable(id)
                } catch {
                    // A folder of three thousand files that dies on the corrupt
                    // one is unusable. A failure is a recorded skip.
                    collector.skip(id)
                }
            }

            let (fresh, failed, elsewhere) = collector.drain()
            for entry in fresh { kept[entry.id] = entry }
            skipped.append(contentsOf: failed)
            unavailable.append(contentsOf: elsewhere)
            report(kept.count, skipped.count, unavailable.count, descriptors.count, reused)

            // The thumbnail is on disk before the manifest names it, so a
            // checkpoint never promises pixels that are not there.
            manifest.entries = Array(kept.values)
            manifest.skipped = Array(leftOut.skipped.union(skipped))
            manifest.unavailable = Array(leftOut.unavailable.union(unavailable))
            try store.save(manifest)
        }
        if isCancelled?() == true { cancelled = true }
        return Round(kept: kept, skipped: skipped, unavailable: unavailable, cancelled: cancelled)
    }

    private func finish(
        _ manifest: inout IndexManifest, kept: [String: IndexEntry], skipped: [String], unavailable: [String],
        store: PhotoIndexStore
    ) throws -> IndexManifest {
        manifest.entries = Array(kept.values)
        manifest.skipped = skipped
        manifest.unavailable = unavailable
        manifest.entries.sort { $0.id < $1.id }
        manifest.skipped.sort()
        manifest.unavailable.sort()
        try store.save(manifest)

        // Only once the manifest is the truth on disk.
        _ = try? store.collectOrphans(keeping: Set(manifest.entries.map(\.thumbnail)))

        return manifest
    }

    /// Decoded once, whole: faces are looked for in the upright photograph and
    /// the crop is cut from the same pixels, so the face-aware crop costs Vision
    /// (~40 ms a photograph at 854 px, measured 2026-10-02) and no second decode.
    static func canonicalImage(
        of id: PhotoID, from source: some PhotoSource, width: Int, rule: CropRule
    ) throws -> (CGImage, cropStart: Double?) {
        switch rule {
        case .centre:
            return (try source.canonicalImage(for: id, maxPixelWidth: width), nil)
        case .faces:
            let upright = try source.uprightImage(for: id, cropWidth: width)
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

/// The one piece of shared state in a concurrent build.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [IndexEntry] = []
    private var failures: [String] = []
    private var elsewhere: [String] = []

    func add(_ entry: IndexEntry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    func skip(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        failures.append(id)
    }

    func unavailable(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        elsewhere.append(id)
    }

    func drain() -> ([IndexEntry], [String], [String]) {
        lock.lock(); defer { lock.unlock() }
        defer { entries = []; failures = []; elsewhere = [] }
        return (entries, failures, elsewhere)
    }
}
