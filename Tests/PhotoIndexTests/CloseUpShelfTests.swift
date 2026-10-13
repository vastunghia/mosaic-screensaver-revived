import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Testing
@testable import PhotoIndex

/// The shelf is how the .saver gets close-ups sharper than a thumbnail without
/// ever touching an original: the app stocks it, the saver reads it.
/// Synthetic photographs of which some are not on this Mac.
private final class AwaySource: PhotoSource, @unchecked Sendable {
    let base: SyntheticPhotoSource
    let away: Set<String>

    init(_ base: SyntheticPhotoSource, away: Set<String>) {
        self.base = base
        self.away = away
    }

    func photos() throws -> [PhotoDescriptor] { try base.photos() }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        if away.contains(id.rawValue) { throw PhotoSourceError.unavailable(id) }
        return try base.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }
}

/// iCloud, as the shelf sees it: some photographs too slow to wait for, and
/// a count of how many requests are out at once.
private final class CloudSource: PhotoSource, @unchecked Sendable {
    let base: SyntheticPhotoSource
    let slow: Set<String>
    /// Too slow the first time only, as iCloud waking up.
    let slowOnce: Set<String>
    private let lock = NSLock()
    private var running = 0
    private var asked: Set<String> = []
    private(set) var mostAtOnce = 0
    /// Every request, in the order made.
    private(set) var order: [String] = []

    init(_ base: SyntheticPhotoSource, slow: Set<String>, slowOnce: Set<String> = []) {
        self.base = base
        self.slow = slow
        self.slowOnce = slowOnce
    }

    func photos() throws -> [PhotoDescriptor] { try base.photos() }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        lock.lock()
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        let first = asked.insert(id.rawValue).inserted
        order.append(id.rawValue)
        lock.unlock()
        defer { lock.lock(); running -= 1; lock.unlock() }
        Thread.sleep(forTimeInterval: 0.05)
        if slow.contains(id.rawValue) || first && slowOnce.contains(id.rawValue) {
            throw PhotoSourceError.timedOut(id)
        }
        return try base.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }
}

@Suite("Close-up shelf")
struct CloseUpShelfTests {
    private let thumbnailWidth = 32
    private let shelfWidth = 64

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-shelf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small real index, with the originals behind it, and an empty shelf.
    private func fixture(count: Int = 5) throws -> (IndexedPhotoSource, CloseUpShelf) {
        let root = temporaryDirectory()
        let source = SyntheticPhotoSource(count: count)
        let store = PhotoIndexStore(directory: root.appendingPathComponent("index"))
        try PhotoIndexBuilder(thumbnailWidth: thumbnailWidth, signatureSide: 2, cropRule: .centre)
            .build(from: source, into: store, root: "synthetic")
        let index = try IndexedPhotoSource(store: store, originals: source)
        return (index, CloseUpShelf(directory: root.appendingPathComponent("closeups"), width: shelfWidth))
    }

    @Test("stocking makes one rendition per photograph, at the shelf's width, once")
    func stock() throws {
        let (index, shelf) = try fixture()
        let first = try shelf.stock(from: index)
        #expect(first.made == 5 && first.kept == 0 && first.failed == 0)
        for entry in index.entries {
            #expect(try shelf.read(entry, maxPixelWidth: shelfWidth).width == shelfWidth)
        }

        let second = try shelf.stock(from: index)
        #expect(second.made == 0 && second.kept == 5, "nothing is made twice")
    }

    @Test("without originals there is nothing to stock from")
    func noOriginals() throws {
        let (index, shelf) = try fixture()
        let bare = IndexedPhotoSource(store: index.store, manifest: index.manifest)
        #expect(throws: CloseUpShelfError.self) { try shelf.stock(from: bare) }
    }

    @Test("a rendition's name changes with the window and the width")
    func names() {
        func entry(_ cropStart: Double?) -> IndexEntry {
            IndexEntry(
                id: "a", versionToken: "1", thumbnail: "thumbs/none.jpg",
                signature: TileSignature(side: 1, cells: [LinearRGB(r: 0, g: 0, b: 0)]),
                pixelWidth: 16, pixelHeight: 9, cropStart: cropStart
            )
        }
        let shelf = CloseUpShelf(directory: URL(fileURLWithPath: "/shelf"), width: 1920)
        let names = [entry(nil), entry(0), entry(0.25)].map(shelf.name(for:))
        #expect(Set(names).count == 3)
        #expect(CloseUpShelf(directory: shelf.directory, width: 2560).name(for: entry(nil)) != names[0])
        #expect(shelf.name(for: entry(0.25)) == names[2], "a pure function of the entry")
    }

    @Test("the saver's source serves the shelf, and the thumbnail where it has a gap")
    func fallback() throws {
        let (index, shelf) = try fixture()
        try shelf.stock(from: index)
        let gap = index.entries[0]
        try FileManager.default.removeItem(at: shelf.url(for: gap))

        let bare = IndexedPhotoSource(store: index.store, manifest: index.manifest)
        let shelved = ShelvedPhotoSource(index: bare, shelf: shelf)

        #expect(try shelved.canonicalImage(for: index.entries[1].photoID, maxPixelWidth: shelfWidth).width == shelfWidth)
        #expect(try shelved.canonicalImage(for: gap.photoID, maxPixelWidth: shelfWidth).width == thumbnailWidth)
        // No wider than a thumbnail: the thumbnail, and neither count moves.
        #expect(try shelved.canonicalImage(for: index.entries[1].photoID, maxPixelWidth: 16).width == 16)
        #expect(shelved.served == 1)
        #expect(shelved.fallbacks == 1)
    }

    @Test("renditions of photographs gone from the index, and half-written ones, are collected")
    func orphans() throws {
        let (index, shelf) = try fixture()
        try shelf.stock(from: index)
        let bucket = shelf.directory.appendingPathComponent("zz", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try Data([1]).write(to: bucket.appendingPathComponent("gone.jpg"))
        try Data([1]).write(to: shelf.url(for: index.entries[0]).appendingPathExtension("partial"))

        let report = try shelf.stock(from: index)
        #expect(report.removed == 2)
        #expect(index.entries.allSatisfy(shelf.has))
    }

    @Test("close-ups this Mac lacks are fetched, one ledger entry each, up to the caps")
    func fetching() throws {
        let (index, shelf) = try fixture(count: 8)
        let synthetic = SyntheticPhotoSource(count: 8)
        let away = Set(index.entries.prefix(6).map(\.id))
        let local = IndexedPhotoSource(
            store: index.store, manifest: index.manifest, originals: AwaySource(synthetic, away: away)
        )
        let ledger = temporaryDirectory().appendingPathComponent("ledger.json")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func fetching(at date: Date) -> CloseUpShelf.Fetching {
            CloseUpShelf.Fetching(index: index, ledger: ledger, dailyLimit: 4, weeklyLimit: 5, now: { date })
        }

        let first = try shelf.stock(from: local, fetching: fetching(at: now))
        #expect(first.made == 6 && first.fetched == 4, "two here, four fetched")
        #expect(first.unavailable == 2 && first.deferred == 2)
        #expect(DownloadLedger.load(from: ledger).requests.count == 4)

        // Within the day: the daily cap holds.
        let soon = try shelf.stock(from: local, fetching: fetching(at: now.addingTimeInterval(3600)))
        #expect(soon.fetched == 0 && soon.deferred == 2)

        // A day later the weekly cap leaves room for one.
        let later = try shelf.stock(from: local, fetching: fetching(at: now.addingTimeInterval(86_400 + 1)))
        #expect(later.fetched == 1 && later.deferred == 1)

        // Nothing is fetched without being asked to.
        let plain = try shelf.stock(from: local)
        #expect(plain.fetched == 0 && plain.unavailable == 1)
    }

    @Test("close-ups may be fetched a few at a time; one too slow is given up on, counted apart")
    func fetchingInParallel() throws {
        let (index, shelf) = try fixture(count: 10)
        let synthetic = SyntheticPhotoSource(count: 10)
        let away = Set(index.entries.map(\.id))
        let local = IndexedPhotoSource(
            store: index.store, manifest: index.manifest, originals: AwaySource(synthetic, away: away)
        )
        let sorted = index.entries.map(\.id).sorted()
        let cloud = CloudSource(synthetic, slow: [sorted[1], sorted[6]])
        let fetching = CloseUpShelf.Fetching(
            index: IndexedPhotoSource(store: index.store, manifest: index.manifest, originals: cloud),
            ledger: temporaryDirectory().appendingPathComponent("ledger.json"),
            dailyLimit: 9, weeklyLimit: 20, concurrency: 3
        )
        let progress = ProgressLog()
        let report = try shelf.stock(from: local, fetching: fetching, progress: { progress.append($0) })

        #expect(cloud.mostAtOnce == 3)
        // The two given up on give their places back: the tenth is asked
        // too, and then the two again, as slow as before.
        #expect(report.toFetch == 12 && report.asked == 12)
        #expect(report.fetched == 8 && report.timedOut == 2)
        #expect(report.unavailable == 2 && report.deferred == 0)
        #expect(progress.asked == [0, 3, 6, 9, 10, 11, 12], "one place left for each retry")
        let ledger = DownloadLedger.load(from: fetching.ledger)
        #expect(ledger.requests.count == 8 && ledger.abandoned.count == 4)
    }

    @Test("those given up on while iCloud wakes up come in when asked again at the end")
    func slowAtFirst() throws {
        let (index, shelf) = try fixture(count: 6)
        let synthetic = SyntheticPhotoSource(count: 6)
        let local = IndexedPhotoSource(
            store: index.store, manifest: index.manifest,
            originals: AwaySource(synthetic, away: Set(index.entries.map(\.id)))
        )
        let sorted = index.entries.map(\.id).sorted()
        let cloud = CloudSource(synthetic, slow: [], slowOnce: Set(sorted.prefix(2)))
        let fetching = CloseUpShelf.Fetching(
            index: IndexedPhotoSource(store: index.store, manifest: index.manifest, originals: cloud),
            ledger: temporaryDirectory().appendingPathComponent("ledger.json")
        )
        let report = try shelf.stock(from: local, fetching: fetching)
        #expect(cloud.mostAtOnce == 1, "one at a time by default")
        #expect(report.made == 6 && report.fetched == 6 && report.timedOut == 0 && report.unavailable == 0)
        #expect(report.asked == 8 && report.toFetch == 8)
        let ledger = DownloadLedger.load(from: fetching.ledger)
        #expect(ledger.requests.count == 6 && ledger.abandoned.count == 2)
        #expect(ledger.slow.isEmpty, "come in at the end: nothing to remember")
    }

    @Test("three given up on in a row stop the run, and do not count towards a rest")
    func stall() throws {
        let (index, shelf) = try fixture(count: 8)
        let synthetic = SyntheticPhotoSource(count: 8)
        let local = IndexedPhotoSource(
            store: index.store, manifest: index.manifest,
            originals: AwaySource(synthetic, away: Set(index.entries.map(\.id)))
        )
        let sorted = index.entries.map(\.id).sorted()
        // One slow on its own, then iCloud stops answering from the fourth.
        let cloud = CloudSource(synthetic, slow: Set([sorted[1]] + sorted[3...]))
        let fetching = CloseUpShelf.Fetching(
            index: IndexedPhotoSource(store: index.store, manifest: index.manifest, originals: cloud),
            ledger: temporaryDirectory().appendingPathComponent("ledger.json")
        )
        let report = try shelf.stock(from: local, fetching: fetching)
        #expect(report.stalled)
        #expect(report.asked == 6 && report.fetched == 2 && report.timedOut == 4)
        #expect(report.deferred == 0 && report.leftForLater == 2 && report.toFetch == 6)
        let ledger = DownloadLedger.load(from: fetching.ledger)
        #expect(ledger.slow.filter { $0.value.runs > 0 }.map(\.key) == [sorted[1]],
                "only the one slow on its own counts")
        #expect(ledger.requests.count == 2 && ledger.abandoned.count == 4)

        // Next time those it stalled on come last: the two never asked come
        // in before the run stops again.
        let again = try shelf.stock(from: local, fetching: fetching)
        #expect(cloud.order.suffix(again.asked).prefix(2) == sorted[6...].prefix(2))
        #expect(again.stalled && again.fetched == 0)
    }

    @Test("one never fetched in time rests after three runs, and is not asked for while it does")
    func alwaysSlow() throws {
        let (index, shelf) = try fixture(count: 4)
        let synthetic = SyntheticPhotoSource(count: 4)
        let away = Set(index.entries.map(\.id))
        let local = IndexedPhotoSource(
            store: index.store, manifest: index.manifest, originals: AwaySource(synthetic, away: away)
        )
        let doomed = index.entries.map(\.id).sorted()[0]
        let cloud = CloudSource(synthetic, slow: [doomed])
        let ledger = temporaryDirectory().appendingPathComponent("ledger.json")
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func run(at date: Date) throws -> CloseUpShelf.StockReport {
            try shelf.stock(from: local, fetching: CloseUpShelf.Fetching(
                index: IndexedPhotoSource(store: index.store, manifest: index.manifest, originals: cloud),
                ledger: ledger, now: { date }
            ))
        }

        for hour in 0..<3 {
            let report = try run(at: start.addingTimeInterval(Double(hour) * 3600))
            #expect(report.timedOut == 1 && report.resting == 0, "run \(hour + 1)")
        }
        #expect(DownloadLedger.load(from: ledger).resting(at: start.addingTimeInterval(3 * 3600)) == [doomed])

        let resting = try run(at: start.addingTimeInterval(3 * 3600))
        #expect(resting.asked == 0 && resting.resting == 1 && resting.unavailable == 1)

        let weekLater = try run(at: start.addingTimeInterval(2 * 3600 + DownloadLedger.standardRest + 1))
        #expect(weekLater.asked == 2 && weekLater.timedOut == 1, "asked again after its rest")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [CloseUpShelf.StockReport] = []

    func append(_ report: CloseUpShelf.StockReport) {
        lock.lock(); reports.append(report); lock.unlock()
    }

    /// While fetching: how many had been asked for at each report.
    var asked: [Int] {
        lock.lock(); defer { lock.unlock() }
        return reports.filter { $0.toFetch > 0 }.map(\.asked)
    }
}
