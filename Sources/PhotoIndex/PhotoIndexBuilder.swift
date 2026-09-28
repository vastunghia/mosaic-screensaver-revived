import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos

public struct IndexProgress: Equatable, Sendable {
    public var completed: Int
    public var reused: Int
    public var skipped: Int
    /// Not on this Mac, and not allowed to be fetched: see `PhotoSourceError.unavailable`.
    public var unavailable: Int
    public var total: Int

    public init(completed: Int = 0, reused: Int = 0, skipped: Int = 0, unavailable: Int = 0, total: Int = 0) {
        self.completed = completed
        self.reused = reused
        self.skipped = skipped
        self.unavailable = unavailable
        self.total = total
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

    /// How often progress is written down. Small enough that a crash loses
    /// seconds, large enough that the manifest is not rewritten per photograph.
    public var checkpointEvery: Int

    public init(
        thumbnailWidth: Int = PhotoIndexBuilder.defaultThumbnailWidth,
        signatureSide: Int = PhotoIndexBuilder.defaultSignatureSide,
        checkpointEvery: Int = 250
    ) {
        self.thumbnailWidth = thumbnailWidth
        self.signatureSide = signatureSide
        self.checkpointEvery = checkpointEvery
    }

    @discardableResult
    public func build(
        from source: some PhotoSource,
        into store: PhotoIndexStore,
        root: String,
        progress: (@Sendable (IndexProgress) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> IndexManifest {
        let descriptors = try source.photos()

        let existing = try store.load()
        var manifest: IndexManifest
        var known: [String: IndexEntry] = [:]
        var alreadySkipped: Set<String> = []

        if let existing, existing.matches(
            root: root, thumbnailWidth: thumbnailWidth, signatureSide: signatureSide
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
                entries: [],
                skipped: []
            )
        }

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

        var state = IndexProgress(
            completed: kept.count, reused: kept.count, skipped: skipped.count,
            total: descriptors.count
        )
        progress?(state)

        let collector = Collector()
        let width = thumbnailWidth
        let side = signatureSide

        for batch in stride(from: 0, to: outstanding.count, by: checkpointEvery) {
            if isCancelled?() == true { break }
            let slice = Array(outstanding[batch..<min(batch + checkpointEvery, outstanding.count)])

            // Decoding is the whole cost and the photographs are independent, so
            // it runs on every core. The collector is the only shared state.
            DispatchQueue.concurrentPerform(iterations: slice.count) { offset in
                let descriptor = slice[offset]
                let id = descriptor.id.rawValue
                do {
                    let image = try source.canonicalImage(for: descriptor.id, maxPixelWidth: width)
                    let signature = try ImageSampling.signature(of: image, side: side)
                    let name = IndexEntry.thumbnailName(id: id, versionToken: descriptor.versionToken)
                    try store.writeThumbnail(image, named: name)
                    collector.add(IndexEntry(
                        id: id,
                        versionToken: descriptor.versionToken,
                        thumbnail: name,
                        signature: signature,
                        pixelWidth: image.width,
                        pixelHeight: image.height
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

            state.completed = kept.count + skipped.count + unavailable.count
            state.skipped = skipped.count
            state.unavailable = unavailable.count
            progress?(state)

            // The thumbnail is on disk before the manifest names it, so a
            // checkpoint never promises pixels that are not there.
            manifest.entries = Array(kept.values)
            manifest.skipped = skipped
            manifest.unavailable = unavailable
            try store.save(manifest)
        }

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
