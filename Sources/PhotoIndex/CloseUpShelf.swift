import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MosaicCore
import MosaicPhotos
import UniformTypeIdentifiers

/// Close-ups made ahead of time, for a host that has no originals.
///
/// The anchor of a cycle fills the screen, and the index's thumbnails are 854
/// across: enlarged to a 4K display they are soft. The app can decode an
/// original whenever it likes; the .saver cannot, so the app leaves one
/// rendition per photograph here, at the anchor's width, and the saver reads
/// it like a thumbnail.
///
/// A rendition is cut **through the index** — `IndexedPhotoSource` with the
/// originals behind it — so it follows the window the thumbnail was cut from,
/// and the crossfade into it does not jump.
///
/// Its name is a hash of everything its pixels depend on: identifier, version,
/// window and width. A photograph edited, recropped by a new rule or wanted at
/// another width gets a new name, so a stale rendition is never served; it is
/// only an orphan, collected like a thumbnail.
public struct CloseUpShelf: Sendable {
    public let directory: URL
    public let width: Int

    public init(directory: URL, width: Int) {
        self.directory = directory.standardizedFileURL
        self.width = width
    }

    public func name(for entry: IndexEntry) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(entry.id.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(entry.versionToken.utf8))
        hasher.update(data: Data([0]))
        // Rounded, not the exact bits: the window has been through JSON, and
        // two parsers can read the same decimals a bit apart. A billionth of
        // the photograph is the same cut in pixels.
        let window = entry.cropStart.map { String(format: "%.9f", $0) } ?? "centre"
        hasher.update(data: Data("\(window)\u{0}\(width)".utf8))
        let hex = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(2))/\(hex).jpg"
    }

    public func url(for entry: IndexEntry) -> URL {
        directory.appendingPathComponent(name(for: entry))
    }

    public func has(_ entry: IndexEntry) -> Bool {
        FileManager.default.fileExists(atPath: url(for: entry).path)
    }

    /// The rendition, at most `maxPixelWidth` across. It is already the
    /// canonical crop, so this only decodes, reduced when asked for less.
    public func read(_ entry: IndexEntry, maxPixelWidth: Int) throws -> CGImage {
        let url = url(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoIndexError.couldNotReadThumbnail(name(for: entry))
        }
        let image: CGImage?
        if maxPixelWidth < width {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelWidth,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw PhotoIndexError.couldNotReadThumbnail(name(for: entry)) }
        return image
    }

    /// Written beside its final name and renamed into place: the saver may be
    /// reading the shelf while the app fills it, and must find either nothing
    /// or a whole JPEG.
    public func write(_ image: CGImage, for entry: IndexEntry) throws {
        let url = url(for: entry)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let partial = url.appendingPathExtension("partial")
        guard let destination = CGImageDestinationCreateWithURL(
            partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw PhotoIndexError.couldNotWriteThumbnail(name(for: entry))
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw PhotoIndexError.couldNotWriteThumbnail(name(for: entry))
        }
        if rename(partial.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: partial)
            throw PhotoIndexError.couldNotWriteThumbnail(name(for: entry))
        }
    }

    public struct StockReport: Sendable {
        public var made = 0
        public var kept = 0
        public var failed = 0
        public var unavailable = 0
        public var removed = 0
        public var total = 0
        /// Tiles only, left out: they never fill the screen (SPEC § 5), and
        /// this Mac has nothing of them this large anyway.
        public var tilesOnly = 0
        /// How many this run makes from what this Mac has, and how many of
        /// those it has tried so far: the window's progress before it fetches.
        public var toMake = 0
        public var tried = 0
        /// Of `made`, fetched from iCloud (`Fetching`).
        public var fetched = 0
        /// Of `unavailable`, not fetched because the ledger's caps were reached.
        public var deferred = 0
        /// How many this run will ask iCloud for, once known, and how many it
        /// has asked for so far: the window's progress while it fetches.
        public var toFetch = 0
        public var asked = 0
        /// Of `unavailable`, asked for and given up on as too slow.
        public var timedOut = 0
        /// Of `unavailable`, not asked for: given up on in too many runs, and
        /// resting (`DownloadLedger`). Only until the next build, which picks
        /// other subjects.
        public var resting = 0
        /// Whether the run stopped because iCloud stopped answering
        /// (`Fetching.standardStallLimit`).
        public var stalled = false
        /// Of `unavailable`, not asked for because the run stopped on a stall.
        public var leftForLater = 0
        /// The tiles picked for the anchor's ring (`IndexManifest.ringPicks`),
        /// asked for after the close-ups: fetched in this run, still to
        /// fetch, and of those, held back by the caps.
        public var ringFetched = 0
        public var ringWaiting = 0
        public var ringDeferred = 0
    }

    /// Where the close-ups this Mac does not have may come from: the index
    /// with originals that may be fetched from iCloud, `concurrency` at a
    /// time (one by default), as many as `ledger` allows (SPEC § 5). Only for the photographs
    /// that fill the screen, and only at the shelf's width: never an original.
    public struct Fetching: Sendable {
        /// One at a time: four at a time each took two or three times as long
        /// (9–13 s against a median of 4.5), and the first four all ran out
        /// of time (2026-10-13).
        public static let standardConcurrency = 1
        /// Seconds a fetch may take before it is given up on, for the source
        /// behind `index` to apply. Of 128 asked one at a time with no limit
        /// (2026-10-13), 118 took under 12.6 s and the other 10 over 32 s,
        /// up to 6 minutes: 15 s gives up on those 10 and takes 12 minutes
        /// instead of 33.
        public static let standardTimeout: TimeInterval = 15
        /// Given up on in a row, at their first request, before the run stops:
        /// iCloud is not answering. On 2026-10-13 it stopped for six minutes
        /// halfway through a run, 17 were given up on one after the other,
        /// and the same came in within seconds afterwards. Those given up on
        /// in a stall do not count towards a rest (`DownloadLedger`).
        public static let standardStallLimit = 3

        public var index: IndexedPhotoSource
        public var ledger: URL
        public var dailyLimit: Int
        public var weeklyLimit: Int
        public var concurrency: Int
        public var stallLimit: Int
        /// The width the ring's picks are fetched at.
        public var ringWidth: Int
        public var now: @Sendable () -> Date

        public init(
            index: IndexedPhotoSource, ledger: URL, dailyLimit: Int = DownloadLedger.standardDailyLimit,
            weeklyLimit: Int = DownloadLedger.standardWeeklyLimit, concurrency: Int = Self.standardConcurrency,
            stallLimit: Int = Self.standardStallLimit,
            ringWidth: Int = PhotoIndexBuilder.CloseUpPreference.standardRingWidth,
            now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.index = index
            self.ledger = ledger
            self.dailyLimit = dailyLimit
            self.weeklyLimit = weeklyLimit
            self.concurrency = max(1, concurrency)
            self.stallLimit = max(1, stallLimit)
            self.ringWidth = ringWidth
            self.now = now
        }
    }

    /// Makes the renditions `index` has no rendition for, then removes those
    /// of photographs no longer in it. `index` must have originals behind it:
    /// from the thumbnails alone this would only enlarge them. With
    /// `fetching`, those this Mac does not have are then fetched, within its
    /// caps.
    ///
    /// Stopped halfway, it leaves whole files behind and picks up from there
    /// next time. Without `collectsOrphans` it removes nothing: a saver may be
    /// reading them, or they belong to another generation of the index, and
    /// the host collects them later (`IndexHousekeeping`).
    @discardableResult
    public func stock(
        from index: IndexedPhotoSource,
        fetching: Fetching? = nil,
        collectsOrphans: Bool = true,
        progress: (@Sendable (StockReport) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> StockReport {
        guard index.originals != nil else { throw CloseUpShelfError.noOriginals }
        guard width > index.manifest.thumbnailWidth else { throw CloseUpShelfError.notWiderThanThumbnails }

        // The subjects too: with close-ups fetched, one this Mac has only as a
        // tile is a subject waiting for its close-up (`PhotoIndexBuilder`).
        let subjects = Set(index.manifest.subjects)
        let entries = index.entries.filter { $0.canFillScreen || subjects.contains($0.id) }
        let missing = entries.filter { !has($0) }
        var report = StockReport(kept: entries.count - missing.count, total: entries.count)
        report.tilesOnly = index.entries.count - entries.count
        // And, made only from what is here, never fetched nor counted as
        // missing, the tiles kept from the screen by their role alone: with
        // close-ups fetched, one that is not a subject fills the screen once
        // its close-up is here (`PhotoIndexBuilder`).
        let narrowest = index.manifest.thumbnailWidth - 1
        let spares = index.entries.filter { !$0.canFillScreen && !subjects.contains($0.id) && $0.pixelWidth >= narrowest }
        let spareIDs = Set(spares.map(\.id))
        let attempted = missing + spares.filter { !has($0) }
        report.toMake = attempted.count
        progress?(report)

        let tally = Tally()
        let batchSize = 48
        var cancelled = false
        for batch in stride(from: 0, to: attempted.count, by: batchSize) {
            if isCancelled?() == true {
                cancelled = true
                break
            }
            let slice = Array(attempted[batch..<min(batch + batchSize, attempted.count)])
            // Decoding originals is the whole cost, as for the index.
            DispatchQueue.concurrentPerform(iterations: slice.count) { offset in
                let entry = slice[offset]
                do {
                    let image = try index.canonicalImage(for: entry.photoID, maxPixelWidth: width)
                    try write(image, for: entry)
                    tally.add(\.made)
                } catch PhotoSourceError.unavailable {
                    guard !spareIDs.contains(entry.id) else { return }
                    tally.add(\.unavailable)
                    tally.elsewhere(entry)
                } catch {
                    guard !spareIDs.contains(entry.id) else { return }
                    tally.add(\.failed)
                }
            }
            let counts = tally.counts
            report.made = counts.made
            report.failed = counts.failed
            report.unavailable = counts.unavailable
            report.tried = batch + slice.count
            progress?(report)
        }

        if let fetching, !cancelled {
            cancelled = fetch(tally.elsewhereEntries, width: width, keeps: true, with: fetching, into: &report,
                              progress: progress, isCancelled: isCancelled)
        }
        // Then the tiles picked for the ring, once every close-up has been
        // asked for: within the same caps, and nothing kept here, since the
        // index reads them again from Photos.
        let picks = index.manifest.ringPicks.compactMap { index.entry(for: PhotoID($0)) }
            .filter { $0.pixelWidth < (fetching?.ringWidth ?? 0) - 1 }
        report.ringWaiting = picks.count
        if let fetching, !cancelled, !report.stalled, !picks.isEmpty {
            var ring = StockReport()
            ring.unavailable = picks.count
            let before = report
            cancelled = fetch(
                picks, width: fetching.ringWidth, keeps: false, with: fetching, into: &ring,
                progress: progress.map { progress -> @Sendable (StockReport) -> Void in
                    { ring in
                        var both = before
                        both.asked += ring.asked
                        both.toFetch += ring.toFetch
                        progress(both)
                    }
                },
                isCancelled: isCancelled
            )
            report.ringFetched = ring.fetched
            report.ringWaiting = ring.unavailable
            report.ringDeferred = ring.deferred
            report.stalled = ring.stalled
            report.asked += ring.asked
            report.toFetch += ring.toFetch
        }

        if !cancelled, collectsOrphans {
            report.removed = collectOrphans(keeping: Set((entries + spares).map(name(for:))))
        }
        return report
    }

    /// `concurrency` at a time, in the index's order, each counted in the
    /// ledger before it is asked for, and moved to its abandoned ones when it
    /// is given up on. Those given up on are asked once more at the end: the
    /// first requests of a run ran out of time one after the other while
    /// iCloud woke up, for a minute or more, and the same photographs came in
    /// seconds later (2026-10-13). Returns whether it was stopped.
    ///
    /// `width` is what is asked for; `keeps` writes it to the shelf.
    private func fetch(
        _ entries: [IndexEntry], width: Int, keeps: Bool, with fetching: Fetching, into report: inout StockReport,
        progress: (@Sendable (StockReport) -> Void)?, isCancelled: (@Sendable () -> Bool)?
    ) -> Bool {
        var ledger = DownloadLedger.load(from: fetching.ledger)
        let resting = ledger.resting(at: fetching.now())
        // In the index's order, except that those given up on before come
        // last: a run that stalled on them would stop on them again.
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let sorted = ledger.ordered(entries.map(\.id).filter { !resting.contains($0) }.sorted())
            .compactMap { byID[$0] }
        report.resting = entries.count - sorted.count
        var queue = sorted
        var slow: [IndexEntry] = []
        var retried = false
        // Given up on in this run and not come in since: a run more for each,
        // however the run ends.
        var givenUp: Set<String> = []
        // Given up on at their first request since the last that came in.
        var streak: [String] = []
        var stalled: [String] = []
        defer {
            ledger.gaveUp(on: givenUp, stalled: stalled, at: fetching.now())
            try? ledger.save(to: fetching.ledger)
        }
        func remaining() -> Int {
            ledger.remaining(at: fetching.now(), daily: fetching.dailyLimit, weekly: fetching.weeklyLimit)
        }
        report.toFetch = min(sorted.count, remaining())
        progress?(report)
        var offset = 0
        while true {
            if offset == queue.count, !retried, !slow.isEmpty {
                queue += slow
                retried = true
            }
            guard offset < queue.count else { break }
            if isCancelled?() == true { return true }
            let now = fetching.now()
            let allowed = remaining()
            guard allowed > 0 else { break }
            let batch = Array(queue[offset..<min(offset + min(fetching.concurrency, allowed), queue.count)])
            for _ in batch { ledger.record(at: now) }
            // Not written down, not asked: a ledger that cannot be kept
            // cannot keep the caps either.
            guard (try? ledger.save(to: fetching.ledger)) != nil else { break }
            offset += batch.count

            let tally = Tally()
            Self.onThreads(batch.count) { index in
                let entry = batch[index]
                do {
                    if keeps {
                        let image = try fetching.index.canonicalImage(for: entry.photoID, maxPixelWidth: width)
                        try write(image, for: entry)
                    } else {
                        // Not through the index: at a tile's width it would
                        // serve its own thumbnail.
                        _ = try fetching.index.uprightImage(for: entry.photoID, cropWidth: width)
                    }
                    tally.add(\.made)
                    tally.arrived(entry)
                } catch PhotoSourceError.unavailable {
                    // Still elsewhere: counted as it was.
                } catch PhotoSourceError.timedOut {
                    tally.add(\.unavailable)
                    tally.elsewhere(entry)
                } catch {
                    tally.add(\.failed)
                }
            }
            let counts = tally.counts
            let timedOut = tally.elsewhereEntries.map(\.id)
            givenUp.formUnion(timedOut)
            if !retried {
                streak = tally.arrivedIDs.isEmpty ? streak + timedOut : []
            }
            for id in tally.arrivedIDs {
                givenUp.remove(id)
                ledger.arrived(id)
            }
            if counts.unavailable > 0 {
                let givenUpAt = fetching.now()
                for _ in 0..<counts.unavailable { ledger.abandon(requestedAt: now, at: givenUpAt) }
                try? ledger.save(to: fetching.ledger)
            }
            if !retried { slow += tally.elsewhereEntries }
            report.asked += batch.count
            report.made += counts.made
            report.fetched += counts.made
            report.failed += counts.failed
            report.unavailable -= counts.made + counts.failed
            if retried {
                // Every one asked now was given up on once already.
                report.timedOut -= counts.made + counts.failed
            } else {
                report.timedOut += counts.unavailable
            }
            // One given up on gives its place back, and will be asked again.
            let left = queue.count - offset + (retried ? 0 : slow.count)
            report.toFetch = report.asked + min(left, remaining())
            if streak.count >= fetching.stallLimit {
                // Stalled: nothing more this run, and no rest for those it
                // cost. The next run asks them again.
                givenUp.subtract(streak)
                stalled = streak
                report.stalled = true
                report.toFetch = report.asked
                progress?(report)
                report.leftForLater = sorted.count - min(offset, sorted.count)
                return false
            }
            progress?(report)
        }
        report.deferred = sorted.count - min(offset, sorted.count)
        return false
    }

    /// `work` for `count` indices, each on a thread of its own, and back when
    /// all are done. Not `concurrentPerform`: that runs them one after the
    /// other when the cores are busy (measured in the tests), and a fetch
    /// waits on iCloud, not on a core.
    private static func onThreads(_ count: Int, _ work: @escaping @Sendable (Int) -> Void) {
        let group = DispatchGroup()
        for index in 0..<count {
            group.enter()
            let thread = Thread {
                work(index)
                group.leave()
            }
            thread.qualityOfService = Thread.current.qualityOfService
            thread.start()
        }
        group.wait()
    }

    /// Deletes every file that is not the rendition of one of `wanted`, half
    /// written ones included. The names are rebuilt from the last components
    /// of each URL, for the reason `PhotoIndexStore.collectOrphans` gives.
    @discardableResult
    public func collectOrphans(keeping wanted: Set<String>) -> Int {
        let manager = FileManager.default
        guard let buckets = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for bucket in buckets {
            guard let files = try? manager.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where !wanted.contains("\(bucket.lastPathComponent)/\(file.lastPathComponent)") {
                try? manager.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }
}

public enum CloseUpShelfError: Error, CustomStringConvertible {
    case noOriginals
    case notWiderThanThumbnails

    public var description: String {
        switch self {
        case .noOriginals: return "close-ups can only be made with the originals at hand"
        case .notWiderThanThumbnails: return "close-ups no wider than the thumbnails would add nothing"
        }
    }
}

/// The index, with the shelf's renditions for anything wider than a
/// thumbnail: what the .saver draws its close-ups from.
///
/// A rendition that is not there — the app has not got to it yet, or the
/// photograph was added since — is not a failure: the close-up comes from the
/// thumbnail, enlarged, as it did before there was a shelf, and is counted.
public final class ShelvedPhotoSource: PhotoSource, @unchecked Sendable {
    public let index: IndexedPhotoSource
    public let shelf: CloseUpShelf

    private let lock = NSLock()
    private var servedCount = 0
    private var fallbackCount = 0

    public init(index: IndexedPhotoSource, shelf: CloseUpShelf) {
        self.index = index
        self.shelf = shelf
    }

    public func photos() throws -> [PhotoDescriptor] {
        try index.photos()
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        guard maxPixelWidth > index.manifest.thumbnailWidth, let entry = index.entry(for: id) else {
            return try index.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
        }
        if let image = try? shelf.read(entry, maxPixelWidth: maxPixelWidth) {
            count(\.servedCount)
            return image
        }
        count(\.fallbackCount)
        return try index.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }

    /// Close-ups that came from the shelf.
    public var served: Int {
        lock.lock(); defer { lock.unlock() }
        return servedCount
    }

    /// Close-ups that had no rendition and came from the thumbnail.
    public var fallbacks: Int {
        lock.lock(); defer { lock.unlock() }
        return fallbackCount
    }

    private func count(_ counter: ReferenceWritableKeyPath<ShelvedPhotoSource, Int>) {
        lock.lock(); defer { lock.unlock() }
        self[keyPath: counter] += 1
    }
}

/// Results arrive from every core at once.
private final class Tally: @unchecked Sendable {
    struct Counts {
        var made = 0
        var failed = 0
        var unavailable = 0
    }

    private let lock = NSLock()
    private var value = Counts()
    private var elsewhere: [IndexEntry] = []
    private var made: [String] = []

    func add(_ counter: WritableKeyPath<Counts, Int>) {
        lock.lock(); value[keyPath: counter] += 1; lock.unlock()
    }

    func elsewhere(_ entry: IndexEntry) {
        lock.lock(); elsewhere.append(entry); lock.unlock()
    }

    func arrived(_ entry: IndexEntry) {
        lock.lock(); made.append(entry.id); lock.unlock()
    }

    var arrivedIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var elsewhereEntries: [IndexEntry] {
        lock.lock(); defer { lock.unlock() }
        return elsewhere
    }

    var counts: Counts {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
