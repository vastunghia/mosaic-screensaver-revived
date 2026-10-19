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
    private var _askedAt: [String] = []
    private var _localWidths: [String: Int] = [:]
    private var _originalWidths: [String: Int] = [:]

    /// `sizes` are the upright sizes the descriptors give, by index; the
    /// others give none, as a folder's do.
    init(count: Int, away: Set<String> = [], broken: Set<String> = [], sizes: [Int: (Int, Int)] = [:]) {
        synthetic = SyntheticPhotoSource(count: count)
        let start = Date(timeIntervalSinceReferenceDate: 600_000_000)
        descriptors = (0..<count).map {
            PhotoDescriptor(
                id: SyntheticPhotoSource.id(for: $0), versionToken: "1",
                creationDate: start.addingTimeInterval(Double($0) * 7 * 86_400),
                pixelWidth: sizes[$0]?.0, pixelHeight: sizes[$0]?.1
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
        set { lock.lock(); _asked = newValue; _askedAt = []; lock.unlock() }
    }

    /// Every request, as "id@width".
    var askedAt: [String] {
        lock.lock(); defer { lock.unlock() }
        return _askedAt
    }

    /// The widest crop this Mac has of a photograph, as an optimised library
    /// keeps a derivative; none means the original is here.
    var localWidths: [String: Int] {
        get { lock.lock(); defer { lock.unlock() }; return _localWidths }
        set { lock.lock(); _localWidths = newValue; lock.unlock() }
    }

    /// Photographs whose original is this narrow: whatever is asked, this
    /// is all there is, and it is not "elsewhere".
    var originalWidths: [String: Int] {
        get { lock.lock(); defer { lock.unlock() }; return _originalWidths }
        set { lock.lock(); _originalWidths = newValue; lock.unlock() }
    }

    func photos() throws -> [PhotoDescriptor] { descriptors }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        lock.lock()
        _asked.append(id.rawValue)
        _askedAt.append("\(id.rawValue)@\(maxPixelWidth)")
        let elsewhere = _away.contains(id.rawValue) || (_localWidths[id.rawValue].map { $0 < maxPixelWidth } ?? false)
        let isBroken = _broken.contains(id.rawValue)
        let original = _originalWidths[id.rawValue]
        lock.unlock()
        if elsewhere { throw PhotoSourceError.unavailable(id) }
        if isBroken { throw PhotoSourceError.couldNotRender(id) }
        return try synthetic.canonicalImage(for: id, maxPixelWidth: min(maxPixelWidth, original ?? maxPixelWidth))
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
        PhotoIndexBuilder(
            thumbnailWidth: 64, signatureSide: 4, cropRule: .centre, tileWidths: [32, 16], checkpointEvery: 8
        )
    }

    /// An optimised library in miniature: a fifth whole, half with a
    /// derivative good for a tile at 32, a tenth only at 16, the rest nothing.
    private func optimised(_ count: Int) -> PatchyLibrary {
        let library = PatchyLibrary(count: count)
        var rng = SplitMix64(seed: 77)
        var widths: [String: Int] = [:]
        var away: Set<String> = []
        for id in library.ids {
            switch rng.next() % 10 {
            case 0, 1: break
            case 2, 3, 4, 5, 6: widths[id] = 40
            case 7: widths[id] = 20
            default: away.insert(id)
            }
        }
        library.localWidths = widths
        library.away = away
        return library
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

    @Test("rounds only add: no photograph is asked twice at the same size")
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
            // A photograph that is not here is asked at every size down to the
            // smallest tile, but at each only once.
            let asked = library.askedAt
            #expect(asked.count == Set(asked).count, "\(rule): \(asked.count - Set(asked).count) asked again")
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

        let last = LastProgress()
        _ = try builder().build(from: source, into: store, root: "library", now: now, progress: { last.record($0) })
        let first = try Data(contentsOf: store.manifestURL)
        #expect(last.value?.reused == 0)
        library.asked = []
        _ = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(60), progress: { last.record($0) }
        )
        #expect(library.asked.isEmpty, "read \(library.asked.count) again")
        #expect(try Data(contentsOf: store.manifestURL) == first)
        #expect(last.value?.reused == 40, "all of them reused, the tiles too")
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

    @Test("a share fills the screen, the rest are tiles as large as this Mac has them")
    func twoTiers() throws {
        for rule in SubsetRule.allCases {
            let library = optimised(400)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }

            let last = LastProgress()
            let manifest = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 80, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library",
                progress: { last.record($0) }
            )
            #expect(manifest.entries.count == 80, "\(rule)")
            let fullScreen = manifest.entries.filter(\.canFillScreen)
            #expect(fullScreen.count >= 80 / PhotoIndexBuilder.fullScreenShare, "\(rule): \(fullScreen.count) fill the screen")
            #expect(last.value?.fullScreen == fullScreen.count, "\(rule)")
            for entry in manifest.entries {
                let local = library.localWidths[entry.id]
                #expect(entry.canFillScreen == (local == nil), "\(rule) \(entry.id)")
                if let local {
                    #expect(entry.pixelWidth == (local >= 32 ? 32 : 16), "\(rule) \(entry.id)")
                }
                #expect(!library.away.contains(entry.id), "\(rule)")
            }
            #expect(Set(manifest.belowFullScreen).isSuperset(of: manifest.entries.filter { !$0.canFillScreen }.map(\.id)))
        }
    }

    @Test("the share that fills the screen is the rule's own choice among those that can")
    func fullScreenIsTheRulesChoice() throws {
        let library = optimised(400)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let source = SubsetPhotoSource(library, rule: .random, count: 80, seed: 9)

        let manifest = try builder().build(from: source, into: PhotoIndexStore(directory: index), root: "library")
        let whole = library.descriptors.filter { library.localWidths[$0.id.rawValue] == nil && !library.away.contains($0.id.rawValue) }
        let expected = Set(SubsetRule.random.choose(
            from: whole, count: 80 / PhotoIndexBuilder.fullScreenShare, seed: 9
        ).map(\.id.rawValue))
        #expect(expected.isSubset(of: Set(manifest.entries.filter(\.canFillScreen).map(\.id))))
    }

    @Test("with every photograph here, two tiers change nothing")
    func wholeLibrary() throws {
        for rule in [SubsetRule.random, .recent] {
            let library = PatchyLibrary(count: 200)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let source = SubsetPhotoSource(library, rule: rule, count: 60, seed: 9)

            let manifest = try builder().build(from: source, into: PhotoIndexStore(directory: index), root: "library")
            let chosen = Set(try source.photos().map(\.id.rawValue))
            #expect(Set(manifest.entries.map(\.id)) == chosen, "\(rule)")
            #expect(manifest.entries.allSatisfy { $0.canFillScreen }, "\(rule)")
            #expect(library.asked.count == 60, "\(rule): read \(library.asked.count)")
        }
    }

    @Test("no photograph is asked twice at the same size, and a second build asks nothing")
    func noRequestTwice() throws {
        let library = optimised(400)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .uniformInTime, count: 80, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        _ = try builder().build(from: source, into: store, root: "library", now: now)
        let requests = library.askedAt
        #expect(requests.count == Set(requests).count, "\(requests.count - Set(requests).count) asked again")

        let first = try Data(contentsOf: store.manifestURL)
        library.asked = []
        _ = try builder().build(from: source, into: store, root: "library", now: now.addingTimeInterval(60))
        #expect(library.askedAt.isEmpty, "asked \(library.askedAt.count) again")
        #expect(try Data(contentsOf: store.manifestURL) == first)
    }

    @Test("a tile whose original comes back fills the screen after a day")
    func tileGrowsAfterADay() throws {
        let library = optimised(400)
        let source = SubsetPhotoSource(library, rule: .random, count: 80, seed: 9)
        // The first photograph of the random order, made a tile.
        let first = try #require(SubsetRule.random.choose(from: library.descriptors, count: 1, seed: 9).first?.id.rawValue)
        library.away.remove(first)
        library.localWidths[first] = 40
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let before = try builder().build(from: source, into: store, root: "library", now: now)
        #expect(before.entries.first { $0.id == first }?.canFillScreen == false)

        library.localWidths[first] = nil
        let soon = try builder().build(from: source, into: store, root: "library", now: now.addingTimeInterval(3600))
        #expect(soon.entries.first { $0.id == first }?.canFillScreen == false, "within the day it is not asked")

        let later = try builder().build(
            from: source, into: store, root: "library",
            now: now.addingTimeInterval(PhotoIndexBuilder.unavailableRetryInterval + 1)
        )
        #expect(later.entries.first { $0.id == first }?.canFillScreen == true)
        #expect(later.entries.count == 80)
    }

    @Test("a small original is a tile too: filling the screen takes the full width")
    func smallOriginalsAreTiles() throws {
        let library = PatchyLibrary(count: 200)
        let small = Set(library.ids.prefix(100))
        library.originalWidths = Dictionary(uniqueKeysWithValues: small.map { ($0, 24) })
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 80, seed: 9),
            into: PhotoIndexStore(directory: index), root: "library"
        )
        #expect(manifest.entries.count == 80)
        for entry in manifest.entries {
            #expect(entry.canFillScreen == !small.contains(entry.id), "\(entry.id)")
        }
        #expect(manifest.entries.filter(\.canFillScreen).count >= 80 / PhotoIndexBuilder.fullScreenShare)
    }

    /// Every third a portrait whose original is 40 pixels wide, too narrow for
    /// the 64 of the screen; of the others, those not in `wide` are here only
    /// up to `localWidth`. With `sizes` false the descriptors give no size, as
    /// PhotoKit's sometimes do, and nothing is known to be narrow before it
    /// is read: the build as it was before narrow originals were left out.
    private func narrowPortraits(
        _ count: Int, wide: Set<String>, localWidth: Int, sizes: Bool
    ) -> (library: PatchyLibrary, narrow: Set<String>) {
        let narrow = Set(stride(from: 0, to: count, by: 3))
        let library = PatchyLibrary(
            count: count, sizes: sizes ? Dictionary(uniqueKeysWithValues: (0..<count).map { index in
                (index, narrow.contains(index) ? (40, 60) : (400, 225))
            }) : [:]
        )
        let narrowIDs = Set(narrow.map { SyntheticPhotoSource.id(for: $0).rawValue })
        library.originalWidths = Dictionary(uniqueKeysWithValues: narrowIDs.map { ($0, 40) })
        library.localWidths = Dictionary(uniqueKeysWithValues: library.ids.filter {
            !narrowIDs.contains($0) && !wide.contains($0)
        }.map { ($0, localWidth) })
        return (library, narrowIDs)
    }

    @Test("leaving narrow originals out before they are read changes nothing chosen")
    func narrowExclusionKeepsSubjects() throws {
        for rule in SubsetRule.allCases {
            let probe = PatchyLibrary(count: 400)
            let wide = Set(SubsetRule.random.choose(from: probe.descriptors, count: 120, seed: 4).map(\.id.rawValue))
            var built: [Bool: IndexManifest] = [:]
            var narrow: Set<String> = []
            for sizes in [true, false] {
                let (library, narrowIDs) = narrowPortraits(400, wide: wide, localWidth: 40, sizes: sizes)
                narrow = narrowIDs
                let index = temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: index) }
                built[sizes] = try builder().build(
                    from: SubsetPhotoSource(library, rule: rule, count: 160, seed: 9),
                    into: PhotoIndexStore(directory: index), root: "library"
                )
            }
            let known = try #require(built[true]), unknown = try #require(built[false])
            func screen(_ manifest: IndexManifest) -> Set<String> {
                Set(manifest.entries.filter(\.canFillScreen).map(\.id))
            }
            #expect(screen(known) == screen(unknown), "\(rule)")
            #expect(screen(known).count >= 160 / PhotoIndexBuilder.fullScreenShare, "\(rule)")
            #expect(screen(known).isDisjoint(with: narrow), "\(rule)")
            #expect(Set(known.entries.map(\.id)) == Set(unknown.entries.map(\.id)), "\(rule)")
            // A narrow tile is read once, at the top, as wide as it is; before,
            // one met as a candidate subject was a tile only from below.
            let widths = Dictionary(uniqueKeysWithValues: unknown.entries.map { ($0.id, $0.pixelWidth) })
            for entry in known.entries where !narrow.contains(entry.id) {
                #expect(entry.pixelWidth == widths[entry.id], "\(rule): \(entry.id)")
            }
        }
    }

    @Test("a narrow original is read once, as the tile it is, and never as a candidate subject")
    func narrowExclusionSavesReads() throws {
        let probe = PatchyLibrary(count: 400)
        let wide = Set(SubsetRule.random.choose(from: probe.descriptors, count: 120, seed: 4).map(\.id.rawValue))
        var reads: [Bool: Int] = [:]
        for sizes in [true, false] {
            let (library, narrow) = narrowPortraits(400, wide: wide, localWidth: 40, sizes: sizes)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let manifest = try builder().build(
                from: SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library"
            )
            reads[sizes] = library.asked.filter(narrow.contains).count
            if sizes {
                let tiles = manifest.entries.filter { narrow.contains($0.id) }
                #expect(reads[sizes] == tiles.count, "\(library.askedAt.filter { narrow.contains(String($0.prefix { $0 != "@" })) })")
                #expect(tiles.allSatisfy { $0.pixelWidth == 40 })
            }
        }
        let saved = try #require(reads[false]) - (try #require(reads[true]))
        #expect(saved > 0, "\(saved) reads saved: \(reads)")
    }

    @Test("a narrow original never passes for a close-up here: the subjects come from those that are")
    func preferredSkipsNarrow() throws {
        for rule in SubsetRule.allCases {
            let probe = PatchyLibrary(count: 400)
            let sharp = Set(SubsetRule.random.choose(from: probe.descriptors, count: 60, seed: 3).map(\.id.rawValue))
                .subtracting(stride(from: 0, to: 400, by: 3).map { SyntheticPhotoSource.id(for: $0).rawValue })
            var subjects: [Bool: Set<String>] = [:]
            for sizes in [true, false] {
                let (library, narrow) = narrowPortraits(400, wide: sharp, localWidth: 100, sizes: sizes)
                let index = temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: index) }
                let manifest = try builder().build(
                    from: SubsetPhotoSource(library, rule: rule, count: 160, seed: 9),
                    into: PhotoIndexStore(directory: index), root: "library", preferring: preference()
                )
                subjects[sizes] = Set(manifest.subjects)
                #expect(manifest.subjects.count == 160 / PhotoIndexBuilder.fullScreenShare, "\(rule)")
                #expect(narrow.isDisjoint(with: manifest.subjects), "\(rule)")
                guard sizes else { continue }
                let candidates = library.descriptors.filter { sharp.contains($0.id.rawValue) }
                let expected = Set(rule.choose(from: candidates, count: 160 / PhotoIndexBuilder.fullScreenShare, seed: 9).map(\.id.rawValue))
                #expect(Set(manifest.subjects) == expected, "\(rule)")
                let asked = library.askedAt.filter { $0.hasSuffix("@128") && narrow.contains(String($0.dropLast(4))) }
                #expect(asked.isEmpty, "\(rule): \(asked)")
            }
            let known = try #require(subjects[true]), unknown = try #require(subjects[false])
            // Before, the preferred were the rule's choice among the sharp and
            // the narrow, which pass for close-ups here; each narrow one gave
            // its place up to the plain rule. Only those places change.
            let narrow = Set(stride(from: 0, to: 400, by: 3).map { SyntheticPhotoSource.id(for: $0).rawValue })
            let before = Set(rule.choose(
                from: probe.descriptors.filter { sharp.contains($0.id.rawValue) || narrow.contains($0.id.rawValue) },
                count: 160 / PhotoIndexBuilder.fullScreenShare, seed: 9
            ).map(\.id.rawValue)).subtracting(narrow)
            #expect(before.isSubset(of: unknown), "\(rule)")
            #expect(before.isSubset(of: known), "\(rule)")
            #expect(!unknown.isSubset(of: sharp), "\(rule): the narrow passed for close-ups before")
        }
    }

    /// What `Options.closeUpPreference` passes, at twice the thumbnail's
    /// width, with a shelf that `stocked` says holds a close-up.
    private func preference(
        stocked: Set<String> = [], resting: Set<String> = [], fetches: Bool = false
    ) -> PhotoIndexBuilder.CloseUpPreference {
        PhotoIndexBuilder.CloseUpPreference(
            width: 128, isStocked: { stocked.contains($0.id) }, resting: resting, fetches: fetches
        )
    }

    @Test("with close-ups fetched, the subjects are the rule's choice over the whole library, the small ones tiles for now")
    func fetchedSubjectsFromEverywhere() throws {
        for rule in SubsetRule.allCases {
            let library = optimised(400)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }

            let manifest = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 160, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library",
                preferring: preference(fetches: true)
            )
            let count = 160 / PhotoIndexBuilder.fullScreenShare
            let here = library.descriptors.filter { !library.away.contains($0.id.rawValue) }
            let expected = Set(rule.choose(from: here, count: count, seed: 9).map(\.id.rawValue))
            #expect(Set(manifest.subjects) == expected, "\(rule)")
            #expect(manifest.entries.count == 160, "\(rule)")
            let waiting = manifest.entries.filter { expected.contains($0.id) && !$0.canFillScreen }
            #expect(!waiting.isEmpty, "\(rule): an optimised library has subjects too small here")
            for entry in manifest.entries where expected.contains(entry.id) {
                #expect(entry.canFillScreen == (library.localWidths[entry.id] == nil), "\(rule) \(entry.id)")
            }
        }
    }

    @Test("with close-ups fetched, only the subjects fill the screen, and a tile once its close-up is here")
    func fetchedTilesFillOnceStocked() throws {
        let library = optimised(400)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // Without it, every tile this Mac has whole would want a close-up
        // fetched: 211 instead of 128 on an optimised profile (2026-10-15).
        let first = try builder().build(
            from: source, into: store, root: "library", now: now, preferring: preference(fetches: true)
        )
        let subjects = Set(first.subjects)
        #expect(Set(first.entries.filter(\.canFillScreen).map(\.id)).isSubset(of: subjects))
        let spares = Set(first.entries.filter { !subjects.contains($0.id) && $0.pixelWidth == 64 }.map(\.id))
        try #require(spares.count > 5)
        #expect(first.belowFullScreen.allSatisfy { !spares.contains($0) }, "short for their role, not for pixels")

        // The shelf made some of their close-ups: those fill the screen,
        // and nothing is read again.
        let stocked = Set(spares.sorted().prefix(3))
        library.asked = []
        let second = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(60),
            preferring: preference(stocked: stocked, fetches: true)
        )
        #expect(library.askedAt.isEmpty, "asked \(library.askedAt)")
        #expect(Set(second.subjects) == subjects)
        let full = Set(second.entries.filter(\.canFillScreen).map(\.id))
        #expect(full.subtracting(subjects) == stocked)

        // Downloads turned off: every one this Mac has whole fills the screen
        // again, without being read again.
        library.asked = []
        let off = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(120),
            preferring: preference(fetches: false)
        )
        // Asked at the close-up's width is the subjects' choice looking for
        // close-ups here, not a read.
        let read = library.askedAt.filter { !$0.hasSuffix("@128") }.map { String($0.split(separator: "@")[0]) }
        #expect(read.allSatisfy { !spares.contains($0) }, "a spare was read again: \(read.filter(spares.contains))")
        for entry in off.entries where spares.contains(entry.id) {
            #expect(entry.canFillScreen, "\(entry.id)")
        }
    }

    @Test("with close-ups fetched, tiles are picked for the ring until a share is wide enough, and read again once in")
    func ringPicks() throws {
        let library = optimised(400)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9)
        func ring(_ share: Double) -> PhotoIndexBuilder.CloseUpPreference {
            var preference = preference(fetches: true)
            preference.ringShare = share
            preference.ringWidth = 48
            return preference
        }

        let none = try builder().build(from: source, into: store, root: "library", preferring: ring(0))
        #expect(none.ringPicks.isEmpty, "a share of 0 picks none")

        let first = try builder().build(from: source, into: store, root: "library", preferring: ring(0.5))
        let subjects = Set(first.subjects)
        let sharp = Set(first.entries.filter { $0.pixelWidth >= 47 }.map(\.id)).union(subjects)
        try #require(first.ringPicks.count > 5)
        #expect(first.ringPicks.count == 80 - sharp.count)
        #expect(Set(first.ringPicks).count == first.ringPicks.count)
        let entries = Dictionary(uniqueKeysWithValues: first.entries.map { ($0.id, $0) })
        for id in first.ringPicks {
            let entry = try #require(entries[id])
            #expect(!entry.canFillScreen && entry.pixelWidth < 47 && !subjects.contains(id))
        }

        // Five copies come in: read again at the ring's width, still tiles,
        // and the others stay picked, in their order.
        let arrived = Array(first.ringPicks.prefix(5))
        for id in arrived { library.localWidths[id] = nil }
        library.asked = []
        let second = try builder().build(from: source, into: store, root: "library", preferring: ring(0.5))
        for id in arrived {
            let entry = try #require(second.entries.first { $0.id == id })
            #expect(entry.pixelWidth == 48 && !entry.canFillScreen)
        }
        let askedAtRing = Set(library.askedAt.filter { $0.hasSuffix("@48") }.map { String($0.dropLast(3)) })
        #expect(askedAtRing == Set(first.ringPicks), "only the picks are asked at the ring's width")
        #expect(second.ringPicks == Array(first.ringPicks.dropFirst(5)))
        #expect(Set(second.subjects) == subjects)
    }

    @Test("with close-ups fetched, a photograph whose original is too narrow is never a subject")
    func fetchedSubjectsAreWideEnough() throws {
        // Every third a portrait 40 pixels wide, whose crop is 40 across:
        // a download would bring nothing wider than the 64 of the screen.
        let narrow = Set(stride(from: 0, to: 400, by: 3))
        let library = PatchyLibrary(
            count: 400, sizes: Dictionary(uniqueKeysWithValues: (0..<400).map { index in
                (index, narrow.contains(index) ? (40, 60) : (400, 225))
            })
        )
        let narrowIDs = Set(narrow.map { SyntheticPhotoSource.id(for: $0).rawValue })
        library.originalWidths = Dictionary(uniqueKeysWithValues: narrowIDs.map { ($0, 40) })
        library.localWidths = Dictionary(uniqueKeysWithValues: library.ids.filter { !narrowIDs.contains($0) }.map { ($0, 40) })
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder().build(
            from: SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9),
            into: PhotoIndexStore(directory: index), root: "library",
            preferring: preference(fetches: true)
        )
        #expect(manifest.subjects.count == 160 / PhotoIndexBuilder.fullScreenShare)
        #expect(narrowIDs.isDisjoint(with: manifest.subjects))
        #expect(manifest.entries.count == 160)
    }

    @Test("a subject waiting as a tile fills the screen once its close-up is in, and only it is read again")
    func fetchedSubjectsArePromoted() throws {
        let library = optimised(400)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let before = try builder().build(
            from: source, into: store, root: "library", now: now, preferring: preference(fetches: true)
        )
        let subjects = Set(before.subjects)
        let waiting = Set(before.entries.filter { subjects.contains($0.id) && !$0.canFillScreen }.map(\.id))
        try #require(!waiting.isEmpty)

        // Nothing fetched yet: nothing read again.
        library.asked = []
        let same = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(60),
            preferring: preference(fetches: true)
        )
        #expect(library.askedAt.isEmpty, "asked \(library.askedAt)")
        #expect(Set(same.subjects) == subjects)

        // Fetched, but one: what came in left this Mac a large derivative.
        let fetched = Set(waiting.sorted().dropFirst())
        for id in fetched { library.localWidths[id] = nil }
        library.asked = []
        let after = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(120),
            preferring: preference(stocked: fetched, fetches: true)
        )
        #expect(Set(after.subjects) == subjects)
        #expect(Set(library.asked) == fetched, "asked \(Set(library.asked).subtracting(fetched))")
        let full = Set(after.entries.filter(\.canFillScreen).map(\.id))
        #expect(fetched.isSubset(of: full))
        #expect(!full.contains(waiting.sorted()[0]))
        #expect(Set(after.belowFullScreen).isDisjoint(with: fetched))
        #expect(after.entries.count == 160)
    }

    /// Every photograph fills the screen; those in `sharp` have a close-up
    /// here too, the others are here only up to 100 px.
    private func sharpOnly(_ count: Int, sharp: Set<String>) -> PatchyLibrary {
        let library = PatchyLibrary(count: count)
        library.localWidths = Dictionary(uniqueKeysWithValues: library.ids.filter { !sharp.contains($0) }.map { ($0, 100) })
        return library
    }

    @Test("the subjects are the rule's choice among the photographs whose close-up is here")
    func prefersSharp() throws {
        for rule in SubsetRule.allCases {
            let probe = PatchyLibrary(count: 400)
            let sharp = Set(SubsetRule.random.choose(from: probe.descriptors, count: 80, seed: 3).map(\.id.rawValue))
            let library = sharpOnly(400, sharp: sharp)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }

            let manifest = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 160, seed: 9),
                into: PhotoIndexStore(directory: index), root: "library", preferring: preference()
            )
            let subjects = 160 / PhotoIndexBuilder.fullScreenShare
            let candidates = library.descriptors.filter { sharp.contains($0.id.rawValue) }
            let expected = Set(rule.choose(from: candidates, count: subjects, seed: 9).map(\.id.rawValue))
            #expect(expected.count == subjects, "\(rule)")
            #expect(expected.isSubset(of: Set(manifest.entries.map(\.id))), "\(rule)")
            #expect(manifest.entries.count == 160, "\(rule)")
            #expect(Set(manifest.belowCloseUp).isDisjoint(with: sharp), "\(rule)")
        }
    }

    @Test("too few close-ups here: no more asked for than the target, then the rule as before")
    func sharpSearchIsBounded() throws {
        let library = sharpOnly(400, sharp: [])
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .uniformInTime, count: 40, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let manifest = try builder().build(from: source, into: store, root: "library", now: now, preferring: preference())
        let probes = library.askedAt.filter { $0.hasSuffix("@128") }
        #expect(probes.count <= 40, "\(probes.count) asked at the close-up's width")
        #expect(manifest.belowCloseUp.count == probes.count)
        #expect(manifest.entries.count == 40)
        #expect(manifest.entries.filter(\.canFillScreen).count >= 40 / PhotoIndexBuilder.fullScreenShare)

        // Within the day nothing is asked again, at any width.
        let first = try Data(contentsOf: store.manifestURL)
        library.asked = []
        _ = try builder().build(
            from: source, into: store, root: "library", now: now.addingTimeInterval(60), preferring: preference()
        )
        #expect(library.askedAt.isEmpty, "asked \(library.askedAt)")
        #expect(try Data(contentsOf: store.manifestURL) == first)
    }

    @Test("searching for subjects asks no photograph twice at the close-up's width")
    func sharpSearchAsksOnce() throws {
        // Sharp photographs few and far between, so the search takes many
        // rounds: each must ask only the newcomers.
        let probe = PatchyLibrary(count: 400)
        let sharp = Set(SubsetRule.random.choose(from: probe.descriptors, count: 30, seed: 5).map(\.id.rawValue))
        let library = sharpOnly(400, sharp: sharp)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        _ = try builder().build(
            from: SubsetPhotoSource(library, rule: .uniformInTime, count: 160, seed: 9),
            into: PhotoIndexStore(directory: index), root: "library", preferring: preference()
        )
        let probes = library.askedAt.filter { $0.hasSuffix("@128") }
        #expect(!probes.isEmpty)
        #expect(probes.count == Set(probes).count, "\(probes.count - Set(probes).count) asked again")
    }

    @Test("a subject whose close-up the shelf holds is not asked for")
    func stockedIsNotAsked() throws {
        let library = sharpOnly(200, sharp: [])
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let source = SubsetPhotoSource(library, rule: .random, count: 40, seed: 9)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let before = try builder().build(from: source, into: store, root: "library", now: now)
        let subjects = Set(before.entries.filter(\.canFillScreen).map(\.id))
        // Their close-ups fetched since; a day later every one is asked again.
        library.asked = []
        let after = try builder().build(
            from: source, into: store, root: "library",
            now: now.addingTimeInterval(PhotoIndexBuilder.unavailableRetryInterval + 1),
            preferring: preference(stocked: subjects)
        )
        #expect(!library.askedAt.contains { $0.hasSuffix("@128") && subjects.contains(String($0.dropLast(4))) })
        #expect(subjects.isSubset(of: Set(after.entries.filter(\.canFillScreen).map(\.id))))
    }

    @Test("close-ups fetched within the day keep their subjects: none was fetched for nothing")
    func fetchedSubjectsStay() throws {
        for rule in SubsetRule.allCases {
            let library = sharpOnly(400, sharp: [])
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let store = PhotoIndexStore(directory: index)
            let source = SubsetPhotoSource(library, rule: rule, count: 160, seed: 9)
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

            let before = try builder().build(from: source, into: store, root: "library", now: now, preferring: preference())
            let subjects = Set(before.entries.filter(\.canFillScreen).map(\.id))
            // The shelf fetched them all; the library changed, and the build
            // runs again an hour later.
            library.asked = []
            let after = try builder().build(
                from: source, into: store, root: "library", now: now.addingTimeInterval(3600),
                preferring: preference(stocked: subjects)
            )
            let kept = Set(after.entries.filter(\.canFillScreen).map(\.id))
            #expect(subjects.isSubset(of: kept), "\(rule): \(subjects.subtracting(kept).count) lost")
            #expect(library.asked.isEmpty, "\(rule): \(library.asked.count) asked again")
        }
    }

    @Test("a subject resting from its fetches gives its place to another, and stays a tile")
    func restingSubjectsMakeWay() throws {
        for rule in SubsetRule.allCases {
            let library = sharpOnly(400, sharp: [])
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let store = PhotoIndexStore(directory: index)
            let source = SubsetPhotoSource(library, rule: rule, count: 160, seed: 9)
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

            let before = try builder().build(from: source, into: store, root: "library", now: now, preferring: preference())
            let subjects = before.entries.filter(\.canFillScreen).map(\.id).sorted()
            let resting = Set(subjects.prefix(2))
            let after = try builder().build(
                from: source, into: store, root: "library", now: now.addingTimeInterval(3600),
                preferring: preference(stocked: Set(subjects).subtracting(resting), resting: resting)
            )
            let kept = after.entries.filter(\.canFillScreen)
            #expect(Set(kept.map(\.id)).isDisjoint(with: resting), "\(rule)")
            #expect(kept.count >= 160 / PhotoIndexBuilder.fullScreenShare, "\(rule)")
            #expect(Set(subjects).subtracting(resting).isSubset(of: Set(kept.map(\.id))), "\(rule)")
            let tiles = after.entries.filter { resting.contains($0.id) }
            #expect(tiles.allSatisfy { !$0.canFillScreen }, "\(rule)")
            #expect(after.entries.count == 160, "\(rule)")
        }
    }

    @Test("subjects stay when the shelf holds more close-ups than subjects, and so do those not fetched yet")
    func subjectsStayAmongMoreCloseUps() throws {
        for rule in SubsetRule.allCases {
            let library = sharpOnly(400, sharp: [])
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let store = PhotoIndexStore(directory: index)
            let source = SubsetPhotoSource(library, rule: rule, count: 160, seed: 9)
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

            let before = try builder().build(from: source, into: store, root: "library", now: now, preferring: preference())
            let subjects = before.subjects
            #expect(subjects.count == 160 / PhotoIndexBuilder.fullScreenShare, "\(rule)")
            #expect(before.subjectsChoice == source.choice, "\(rule)")
            // Two subjects not fetched in time; twenty other photographs that
            // fill the screen got close-ups too, as on 2026-10-13.
            let others = before.entries.map(\.id).filter { !subjects.contains($0) }.sorted().prefix(20)
            let stocked = Set(subjects.dropFirst(2)).union(others)
            let after = try builder().build(
                from: source, into: store, root: "library", now: now.addingTimeInterval(3600),
                preferring: preference(stocked: stocked)
            )
            #expect(after.subjects == subjects, "\(rule)")
            #expect(stocked.isSubset(of: Set(after.entries.map(\.id))), "\(rule): a close-up here left the index")
            #expect(after.entries.map(\.id) == before.entries.map(\.id), "\(rule)")
        }
    }

    @Test("another choice starts its subjects afresh")
    func otherChoiceOtherSubjects() throws {
        let library = sharpOnly(400, sharp: [])
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 160, seed: 9), into: store, root: "library",
            now: now, preferring: preference()
        )
        let other = SubsetPhotoSource(library, rule: .random, count: 160, seed: 10)
        let second = try builder().build(
            from: other, into: store, root: "library", now: now.addingTimeInterval(60), preferring: preference()
        )
        let fresh = try builder().build(
            from: other, into: PhotoIndexStore(directory: temporaryDirectory()), root: "library", now: now,
            preferring: preference()
        )
        #expect(second.subjects == fresh.subjects)
        #expect(second.subjects != first.subjects)
    }
}

@Suite("Renewing a subset beside the live one")
struct RenewalTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-renewal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func builder(collectsOrphans: Bool = false) -> PhotoIndexBuilder {
        var builder = PhotoIndexBuilder(
            thumbnailWidth: 64, signatureSide: 4, cropRule: .centre, tileWidths: [32, 16], checkpointEvery: 8
        )
        builder.collectsOrphans = collectsOrphans
        return builder
    }

    private func sharpOnly(_ count: Int, sharp: Set<String>) -> PatchyLibrary {
        let library = PatchyLibrary(count: count)
        library.localWidths = Dictionary(uniqueKeysWithValues: library.ids.filter { !sharp.contains($0) }.map { ($0, 100) })
        return library
    }

    private func preference(stocked: Set<String> = []) -> PhotoIndexBuilder.CloseUpPreference {
        PhotoIndexBuilder.CloseUpPreference(width: 128, isStocked: { stocked.contains($0.id) })
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("the manifest says which subset it holds")
    func choiceWritten() throws {
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let source = SubsetPhotoSource(PatchyLibrary(count: 100), rule: .random, count: 40, seed: 9)
        let manifest = try builder().build(from: source, into: PhotoIndexStore(directory: index), root: "library")
        #expect(manifest.choice == source.choice)
        #expect(try PhotoIndexStore(directory: index).load()?.choice == source.choice)
    }

    @Test("a renewed seed chooses its subjects as from scratch, whatever close-ups the shelf holds for the old ones")
    func subjectsAfresh() throws {
        for rule in SubsetRule.allCases {
            let probe = PatchyLibrary(count: 400)
            let sharp = Set(SubsetRule.random.choose(from: probe.descriptors, count: 80, seed: 3).map(\.id.rawValue))
            let library = sharpOnly(400, sharp: sharp)
            let index = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: index) }
            let store = PhotoIndexStore(directory: index)

            let live = try builder().build(
                from: SubsetPhotoSource(library, rule: rule, count: 160, seed: 9), into: store, root: "library",
                now: now, preferring: preference()
            )
            // The shelf, once stocked, holds a close-up for every one that
            // fills the screen and is here large enough to make it.
            let shelved = Set(live.entries.filter(\.canFillScreen).map(\.id)).intersection(sharp)
            let renewed = SubsetPhotoSource(library, rule: rule, count: 160, seed: 10)
            // Days later, when what the live build found missing is asked
            // again: within the day it would also spend the same day's
            // budget for the search (`preferred`).
            let later = now.addingTimeInterval(2 * 86_400)

            let next = try builder().build(
                from: renewed, into: store.next, root: "library", now: later,
                preferring: preference(stocked: shelved), reusing: live
            )
            let fresh = try builder().build(
                from: renewed, into: PhotoIndexStore(directory: temporaryDirectory()), root: "library",
                now: now, preferring: preference()
            )
            #expect(Set(next.subjects) == Set(fresh.subjects), "\(rule)")
            #expect(Set(next.entries.map(\.id)) == Set(fresh.entries.map(\.id)), "\(rule)")

            // The trap it avoids: the same seed changed in place prefers the
            // close-ups already here, all of the old subset's.
            let inPlace = try builder().build(
                from: renewed, into: store, root: "library", now: later,
                preferring: preference(stocked: shelved)
            )
            #expect(Set(inPlace.subjects).isSubset(of: shelved), "\(rule)")
            // The most recent are the most recent whatever the seed.
            if rule != .recent {
                #expect(!Set(next.subjects).isSubset(of: shelved), "\(rule)")
            }
        }
    }

    @Test("the other generation's thumbnails are taken as they are, and none of its own is deleted")
    func pixelsReused() throws {
        let library = PatchyLibrary(count: 160)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let live = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 9), into: store, root: "library", now: now
        )
        library.asked = []
        let next = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 10), into: store.next,
            root: "library", now: now, reusing: live
        )
        let both = Set(live.entries.map(\.id)).intersection(next.entries.map(\.id))
        #expect(!both.isEmpty)
        #expect(Set(library.asked).isDisjoint(with: both), "read again: \(Set(library.asked).intersection(both))")
        #expect(library.asked.count == next.entries.count - both.count)
        for entry in live.entries + next.entries {
            #expect(store.hasThumbnail(named: entry.thumbnail), "\(entry.id)")
        }
        #expect(try store.load() == live, "the live manifest is untouched")
        #expect(next.subjects.isEmpty && next.ringPicks.isEmpty)
    }

    @Test("what is known of the whole library carries over to the new generation")
    func libraryFactsCarry() throws {
        let library = PatchyLibrary(count: 160)
        library.away = Set(library.ids.prefix(60))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let live = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 9), into: store, root: "library",
            availability: "nothing", now: now
        )
        #expect(!live.unavailable.isEmpty)
        library.asked = []
        let next = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 10), into: store.next,
            root: "library", availability: "nothing", now: now.addingTimeInterval(60), reusing: live
        )
        #expect(Set(library.asked).isDisjoint(with: live.unavailable), "asked again within the day")
        #expect(Set(live.unavailable).isSubset(of: Set(next.unavailable)))
        #expect(next.unavailableCheckedAt == live.unavailableCheckedAt)
    }

    @Test("an interrupted renewal picks up where it stopped, and ends as an uninterrupted one")
    func resumes() throws {
        let library = PatchyLibrary(count: 300)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let live = try builder().build(
            from: SubsetPhotoSource(library, rule: .uniformInTime, count: 80, seed: 9), into: store, root: "library",
            now: now
        )
        let renewed = SubsetPhotoSource(library, rule: .uniformInTime, count: 80, seed: 10)
        let calls = Counter()
        _ = try builder().build(
            from: renewed, into: store.next, root: "library", now: now, reusing: live,
            isCancelled: { calls.increment() > 3 }
        )
        let partial = try #require(try store.next.load())
        #expect(partial.entries.count < 80)
        let resumed = try builder().build(from: renewed, into: store.next, root: "library", now: now, reusing: live)
        let fresh = try builder().build(
            from: renewed, into: PhotoIndexStore(directory: temporaryDirectory()), root: "library", now: now
        )
        #expect(resumed.entries.map(\.id) == fresh.entries.map(\.id))
    }

    @Test("promoting puts the next manifest in place in one rename, and housekeeping then takes the old files")
    func promoteAndCollect() throws {
        let library = PatchyLibrary(count: 160)
        let index = temporaryDirectory()
        let shelfDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(at: shelfDirectory)
        }
        let store = PhotoIndexStore(directory: index)
        let shelf = CloseUpShelf(directory: shelfDirectory, width: 128)
        let live = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 9), into: store, root: "library", now: now
        )
        let next = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 40, seed: 10), into: store.next,
            root: "library", now: now, reusing: live
        )
        let image = try SyntheticPhotoSource(count: 1).canonicalImage(for: SyntheticPhotoSource.id(for: 0), maxPixelWidth: 128)
        for entry in live.entries + next.entries { try shelf.write(image, for: entry) }

        // Both generations on disk: nothing is anybody's orphan.
        #expect(IndexHousekeeping.collect(index: store, shelf: shelf) == .init())

        try store.promote(store.next)
        #expect(try store.load() == next)
        #expect(try store.next.load() == nil)

        let old = Set(live.entries.map(\.id)).subtracting(next.entries.map(\.id))
        let report = IndexHousekeeping.collect(index: store, shelf: shelf)
        #expect(report == .init(thumbnails: old.count, closeUps: old.count))
        for entry in next.entries {
            #expect(store.hasThumbnail(named: entry.thumbnail) && shelf.has(entry), "\(entry.id)")
        }
        for entry in live.entries where old.contains(entry.id) {
            #expect(!store.hasThumbnail(named: entry.thumbnail) && !shelf.has(entry), "\(entry.id)")
        }
    }

    @Test("with no live manifest to read, housekeeping removes nothing")
    func nothingWithoutManifest() throws {
        let library = PatchyLibrary(count: 60)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let next = try builder().build(
            from: SubsetPhotoSource(library, rule: .random, count: 20, seed: 9), into: store.next, root: "library"
        )
        #expect(IndexHousekeeping.collect(index: store, shelf: nil) == .init())
        try Data("not a manifest".utf8).write(to: store.manifestURL)
        #expect(IndexHousekeeping.collect(index: store, shelf: nil) == .init())
        for entry in next.entries { #expect(store.hasThumbnail(named: entry.thumbnail)) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
