import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Testing
@testable import PhotoIndex

/// A library of synthetic photographs, one a week, in which some are elsewhere
/// (iCloud with downloads off) and some broken, and which remembers what it
/// was asked to decode.
private final class PatchyLibrary: PhotoSource, @unchecked Sendable {
    let descriptors: [PhotoDescriptor]
    private let synthetic: SyntheticPhotoSource
    private let lock = NSLock()
    private var _away: Set<String>
    private var _broken: Set<String>
    private var _asked: [String] = []

    init(count: Int, away: Set<String> = [], broken: Set<String> = []) {
        synthetic = SyntheticPhotoSource(count: count)
        let start = Date(timeIntervalSinceReferenceDate: 600_000_000)
        descriptors = (0..<count).map {
            PhotoDescriptor(
                id: SyntheticPhotoSource.id(for: $0), versionToken: "1",
                creationDate: start.addingTimeInterval(Double($0) * 7 * 86_400)
            )
        }
        _away = away
        _broken = broken
    }

    var ids: [String] { descriptors.map(\.id.rawValue) }

    var away: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _away }
        set { lock.lock(); _away = newValue; lock.unlock() }
    }

    var broken: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _broken
    }

    var asked: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _asked }
        set { lock.lock(); _asked = newValue; lock.unlock() }
    }

    func photos() throws -> [PhotoDescriptor] { descriptors }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        lock.lock()
        _asked.append(id.rawValue)
        let elsewhere = _away.contains(id.rawValue)
        let isBroken = _broken.contains(id.rawValue)
        lock.unlock()
        if elsewhere { throw PhotoSourceError.unavailable(id) }
        if isBroken { throw PhotoSourceError.couldNotRender(id) }
        return try synthetic.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }
}

private final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last: IndexProgress?

    func record(_ progress: IndexProgress) {
        lock.lock(); last = progress; lock.unlock()
    }

    var value: IndexProgress? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}

@Suite("Filling a subset to its target")
struct FillTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-fill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func builder() -> PhotoIndexBuilder {
        PhotoIndexBuilder(thumbnailWidth: 64, signatureSide: 4, cropRule: .centre, checkpointEvery: 8)
    }

    /// About every other photograph, drawn with the seed.
    private func half(of library: PatchyLibrary, seed: UInt64) -> Set<String> {
        var rng = SplitMix64(seed: seed)
        return Set(library.ids.filter { _ in rng.next() % 2 == 0 })
    }

    @Test("every rule reaches its target when the library has enough, with nothing missing in it")
    func reachesTarget() throws {
        for rule in SubsetRule.allCases {
            let library = PatchyLibrary(count: 160)
            library.away = half(of: library, seed: 1)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }

            let last = LastProgress()
            let manifest = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 40, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library",
                progress: { last.record($0) }
            )
            let ready = Set(manifest.entries.map(\.id))
            #expect(ready.count == 40, "\(rule)")
            #expect(ready.isDisjoint(with: library.away), "\(rule)")
            #expect(Set(manifest.unavailable).isSubset(of: library.away), "\(rule)")
            #expect(last.value?.ready == 40 && last.value?.total == 40, "\(rule)")
            #expect(last.value?.fellShort == false, "\(rule)")

            // Random and most recent take an order and skip what is missing:
            // the result is the rule's own choice among the available ones.
            if rule != .uniformInTime {
                let available = library.descriptors.filter { !library.away.contains($0.id.rawValue) }
                #expect(ready == Set(rule.choose(from: available, count: 40, seed: 9).map(\.id.rawValue)), "\(rule)")
            }
        }
    }

    @Test("rounds only add: no photograph is read twice")
    func roundsOnlyAdd() throws {
        for rule in SubsetRule.allCases {
            let library = PatchyLibrary(count: 160)
            library.away = half(of: library, seed: 2)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }

            _ = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 40, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library"
            )
            let asked = library.asked
            #expect(asked.count == Set(asked).count, "\(rule): \(asked.count - Set(asked).count) read again")
        }
    }

    @Test("broken photographs are replaced too")
    func replacesBroken() throws {
        let library = PatchyLibrary(count: 60, broken: Set(SubsetRule.random.choose(
            from: PatchyLibrary(count: 60).descriptors, count: 10, seed: 3
        ).map(\.id.rawValue)))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 10, seed: 3),
            into: PhotoIndexStore(directory: index), root: "library"
        )
        #expect(manifest.entries.count == 10)
        #expect(Set(manifest.skipped) == library.broken)
    }

    @Test("a library with too few readable photographs gives all it has, and says so")
    func fallsShort() throws {
        let library = PatchyLibrary(count: 50)
        library.away = Set(library.ids.dropFirst(20))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let last = LastProgress()
        let manifest = try builder().build(
            from: SubsetPhotoSource(library, rule: .uniformInTime, count: 40, seed: 9),
            into: PhotoIndexStore(directory: index), root: "library",
            progress: { last.record($0) }
        )
        #expect(manifest.entries.count == 20)
        #expect(last.value?.fellShort == true)
        #expect(last.value?.ready == 20 && last.value?.total == 20)
    }

    @Test("albums smaller than the target are not falling short")
    func smallerThanTarget() throws {
        let library = PatchyLibrary(count: 30)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let last = LastProgress()
        let manifest = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 9),
            into: PhotoIndexStore(directory: index), root: "library",
            progress: { last.record($0) }
        )
        #expect(manifest.entries.count == 30)
        #expect(last.value?.fellShort == false)
        #expect(last.value?.total == 30)
    }

    @Test("a second build reads nothing and writes the same manifest")
    func idempotent() throws {
        let library = PatchyLibrary(count: 160)
        library.away = half(of: library, seed: 4)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .random, count: 40, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        _ = try builder().build(from: source, into: store, root: "library", now: now)
        let first = try Data(contentsOf: store.manifestURL)
        library.asked = []
        _ = try builder().build(from: source, into: store, root: "library", now: now.addingTimeInterval(60))
        #expect(library.asked.isEmpty, "read \(library.asked.count) again")
        #expect(try Data(contentsOf: store.manifestURL) == first)
    }

    @Test("a photograph that comes back is asked for again after a day, and takes its place")
    func retriesAfterADay() throws {
        let library = PatchyLibrary(count: 160)
        let source = SubsetPhotoSource(library, rule: .random, count: 40, seed: 9)
        let canonical = Set(try source.photos().map(\.id.rawValue))
        let returning = try #require(canonical.sorted().first)
        library.away = half(of: library, seed: 5).union([returning])
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        _ = try builder().build(from: source, into: store, root: "library", now: now)

        // Back on this Mac, but within the day: left out, not asked for.
        library.away.remove(returning)
        library.asked = []
        let soon = try builder().build(from: source, into: store, root: "library", now: now.addingTimeInterval(3600))
        #expect(library.asked.isEmpty)
        #expect(!soon.entries.map(\.id).contains(returning))

        // A day later it is asked for, comes in, and one goes out.
        let later = try builder().build(
            from: source, into: store, root: "library",
            now: now.addingTimeInterval(PhotoIndexBuilder.unavailableRetryInterval + 1)
        )
        #expect(later.entries.map(\.id).contains(returning))
        #expect(later.entries.count == 40)
        // Found out afresh: only those met on the way, and not the one back.
        #expect(Set(later.unavailable).isSubset(of: library.away))
        #expect(!later.unavailable.contains(returning))
    }

    @Test("turning downloads on asks for every photograph left out at once")
    func retriesWhenDownloadsChange() throws {
        let library = PatchyLibrary(count: 160)
        library.away = half(of: library, seed: 6)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .random, count: 40, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        _ = try builder().build(from: source, into: store, root: "library", availability: "local", now: now)
        library.away = []
        let downloaded = try builder().build(
            from: source, into: store, root: "library", availability: "downloads", now: now.addingTimeInterval(60)
        )
        #expect(Set(downloaded.entries.map(\.id)) == Set(try source.photos().map(\.id.rawValue)))
        #expect(downloaded.unavailable.isEmpty)
    }
}
