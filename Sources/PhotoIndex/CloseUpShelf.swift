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
        /// Of `made`, fetched from iCloud (`Fetching`).
        public var fetched = 0
        /// Of `unavailable`, not fetched because the ledger's caps were reached.
        public var deferred = 0
    }

    /// Where the close-ups this Mac does not have may come from: the index
    /// with originals that may be fetched from iCloud, one at a time, as many
    /// as `ledger` allows (SPEC § 5). Only for the photographs that fill the
    /// screen, and only at the shelf's width: never an original.
    public struct Fetching: Sendable {
        public var index: IndexedPhotoSource
        public var ledger: URL
        public var dailyLimit: Int
        public var weeklyLimit: Int
        public var now: @Sendable () -> Date

        public init(
            index: IndexedPhotoSource, ledger: URL, dailyLimit: Int = DownloadLedger.standardDailyLimit,
            weeklyLimit: Int = DownloadLedger.standardWeeklyLimit, now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.index = index
            self.ledger = ledger
            self.dailyLimit = dailyLimit
            self.weeklyLimit = weeklyLimit
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
    /// next time.
    @discardableResult
    public func stock(
        from index: IndexedPhotoSource,
        fetching: Fetching? = nil,
        progress: (@Sendable (StockReport) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> StockReport {
        guard index.originals != nil else { throw CloseUpShelfError.noOriginals }
        guard width > index.manifest.thumbnailWidth else { throw CloseUpShelfError.notWiderThanThumbnails }

        let entries = index.entries.filter(\.canFillScreen)
        let missing = entries.filter { !has($0) }
        var report = StockReport(kept: entries.count - missing.count, total: entries.count)
        report.tilesOnly = index.entries.count - entries.count
        progress?(report)

        let tally = Tally()
        let batchSize = 48
        var cancelled = false
        for batch in stride(from: 0, to: missing.count, by: batchSize) {
            if isCancelled?() == true {
                cancelled = true
                break
            }
            let slice = Array(missing[batch..<min(batch + batchSize, missing.count)])
            // Decoding originals is the whole cost, as for the index.
            DispatchQueue.concurrentPerform(iterations: slice.count) { offset in
                let entry = slice[offset]
                do {
                    let image = try index.canonicalImage(for: entry.photoID, maxPixelWidth: width)
                    try write(image, for: entry)
                    tally.add(\.made)
                } catch PhotoSourceError.unavailable {
                    tally.add(\.unavailable)
                    tally.elsewhere(entry)
                } catch {
                    tally.add(\.failed)
                }
            }
            let counts = tally.counts
            report.made = counts.made
            report.failed = counts.failed
            report.unavailable = counts.unavailable
            progress?(report)
        }

        if let fetching, !cancelled {
            cancelled = fetch(tally.elsewhereEntries, with: fetching, into: &report, progress: progress,
                              isCancelled: isCancelled)
        }

        if !cancelled {
            report.removed = collectOrphans(keeping: Set(entries.map(name(for:))))
        }
        return report
    }

    /// One at a time, in the index's order, each counted in the ledger
    /// before it is asked for. Returns whether it was stopped.
    private func fetch(
        _ entries: [IndexEntry], with fetching: Fetching, into report: inout StockReport,
        progress: (@Sendable (StockReport) -> Void)?, isCancelled: (@Sendable () -> Bool)?
    ) -> Bool {
        var ledger = DownloadLedger.load(from: fetching.ledger)
        for (offset, entry) in entries.sorted(by: { $0.id < $1.id }).enumerated() {
            if isCancelled?() == true { return true }
            let now = fetching.now()
            guard ledger.remaining(at: now, daily: fetching.dailyLimit, weekly: fetching.weeklyLimit) > 0 else {
                report.deferred = entries.count - offset
                break
            }
            ledger.record(at: now)
            // Not written down, not asked: a ledger that cannot be kept
            // cannot keep the caps either.
            guard (try? ledger.save(to: fetching.ledger)) != nil else {
                report.deferred = entries.count - offset
                break
            }
            do {
                let image = try fetching.index.canonicalImage(for: entry.photoID, maxPixelWidth: width)
                try write(image, for: entry)
                report.made += 1
                report.fetched += 1
                report.unavailable -= 1
            } catch PhotoSourceError.unavailable {
                // Still elsewhere: counted as it was.
            } catch {
                report.failed += 1
                report.unavailable -= 1
            }
            progress?(report)
        }
        return false
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

    func add(_ counter: WritableKeyPath<Counts, Int>) {
        lock.lock(); value[keyPath: counter] += 1; lock.unlock()
    }

    func elsewhere(_ entry: IndexEntry) {
        lock.lock(); elsewhere.append(entry); lock.unlock()
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
