import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Testing
@testable import PhotoIndex

/// Photographs whose every pixel spells their number, so that a fake assessor
/// can tell which one Vision was shown; one a week from 2020.
private final class MarkedLibrary: PhotoSource, @unchecked Sendable {
    let descriptors: [PhotoDescriptor]
    private let lock = NSLock()
    private var _decoded: [String] = []
    private var _tokens: [Int: String] = [:]

    init(count: Int) {
        let start = Date(timeIntervalSinceReferenceDate: 600_000_000)
        descriptors = (0..<count).map {
            PhotoDescriptor(
                id: PhotoID(String(format: "p%04d", $0)), versionToken: "1",
                creationDate: start.addingTimeInterval(Double($0) * 7 * 86_400)
            )
        }
    }

    /// A new version of photograph `index`: new pixels, as far as an index knows.
    func edit(_ index: Int) {
        lock.lock(); _tokens[index] = "2"; lock.unlock()
    }

    var decoded: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _decoded }
        set { lock.lock(); _decoded = newValue; lock.unlock() }
    }

    func photos() throws -> [PhotoDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return descriptors.enumerated().map { index, photo in
            PhotoDescriptor(id: photo.id, versionToken: _tokens[index] ?? "1", creationDate: photo.creationDate)
        }
    }

    static func index(of id: PhotoID) -> Int { Int(id.rawValue.dropFirst())! }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        lock.lock(); _decoded.append(id.rawValue); lock.unlock()
        let index = Self.index(of: id)
        let width = maxPixelWidth, height = CanonicalAspect.height(forWidth: maxPixelWidth)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: Self.space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: Self.space,
            components: [CGFloat(index & 0xFF) / 255, CGFloat(index >> 8) / 255, 0.5, 1]
        )!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The number `image` spells.
    static func index(in image: CGImage) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0]) | Int(pixel[1]) << 8
    }
}

/// Vision, faked: a verdict for each photograph by its number, and a count
/// of what it was asked.
private final class FakeAssessor: PhotoAssessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [Int] = []
    private var _scored: [Int] = []
    let utility: Set<Int>
    let scores: [Int: Float]
    let failing: Set<Int>
    var revision: String

    init(utility: Set<Int> = [], scores: [Int: Float] = [:], failing: Set<Int> = [], revision: String = "fake-1") {
        self.utility = utility
        self.scores = scores
        self.failing = failing
        self.revision = revision
    }

    var asked: [Int] { lock.lock(); defer { lock.unlock() }; return _asked }
    var scored: [Int] { lock.lock(); defer { lock.unlock() }; return _scored }

    func assess(_ image: CGImage, small: (Int) -> CGImage?, wantsScore: Bool) throws -> AestheticVerdict {
        let index = MarkedLibrary.index(in: image)
        lock.lock()
        _asked.append(index)
        if wantsScore { _scored.append(index) }
        lock.unlock()
        if failing.contains(index) { throw CancellationError() }
        return AestheticVerdict(
            utility: utility.contains(index), smallUtility: wantsScore ? false : nil,
            score: wantsScore ? scores[index] ?? 0.9 : nil, side: image.width
        )
    }
}

/// Photos' scores, faked.
private struct FakeQualities: PhotoQualitySource {
    var scores: [Int: Double] = [:]
    var screenshots: Set<Int> = []

    func qualities(of photos: [PhotoDescriptor]) -> [PhotoID: PhotoQuality] {
        var qualities: [PhotoID: PhotoQuality] = [:]
        for photo in photos {
            let index = MarkedLibrary.index(of: photo.id)
            if scores[index] != nil || screenshots.contains(index) {
                qualities[photo.id] = PhotoQuality(score: scores[index], isScreenshot: screenshots.contains(index))
            }
        }
        return qualities
    }
}

@Suite("Leaving photographs out of an index")
struct CullingIndexTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-cull-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func builder(_ assessor: (any PhotoAssessing)?) -> PhotoIndexBuilder {
        PhotoIndexBuilder(
            thumbnailWidth: 64, signatureSide: 4, cropRule: .centre, tileWidths: [32], assessor: assessor,
            checkpointEvery: 8
        )
    }

    private func source(
        _ library: MarkedLibrary, count: Int = 40, quality: (any PhotoQualitySource)? = FakeQualities()
    ) -> SubsetPhotoSource<MarkedLibrary> {
        SubsetPhotoSource(library, rule: .uniformInTime, count: count, seed: 4, quality: quality)
    }

    private func indices(_ ids: some Sequence<String>) -> Set<Int> {
        Set(ids.map { MarkedLibrary.index(of: PhotoID($0)) })
    }

    @Test("a utility shot is left out and another takes its place")
    func utilityReplaced() throws {
        let library = MarkedLibrary(count: 160)
        let utility = Set(stride(from: 0, to: 160, by: 3))
        let assessor = FakeAssessor(utility: utility)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder(assessor).build(
            from: source(library), into: PhotoIndexStore(directory: index), root: "library"
        )
        let ready = indices(manifest.entries.map(\.id))
        #expect(ready.count == 40)
        #expect(ready.isDisjoint(with: utility))
        // Every photograph Vision saw is written down, those left out too.
        let judged = indices(manifest.assessments.map(\.id))
        #expect(judged.isSuperset(of: ready))
        #expect(!judged.intersection(utility).isEmpty)
        #expect(manifest.assessments.allSatisfy { $0.revision == "fake-1" })
        // With no scores of Photos', every photograph's score is wanted.
        #expect(Set(assessor.scored) == Set(assessor.asked))
    }

    @Test("a second build asks Vision nothing and decodes nothing it left out")
    func remembered() throws {
        let library = MarkedLibrary(count: 160)
        let utility = Set(stride(from: 0, to: 160, by: 3))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        let first = try builder(FakeAssessor(utility: utility)).build(from: source(library), into: store, root: "library")
        library.decoded = []
        let again = FakeAssessor(utility: utility)
        let second = try builder(again).build(from: source(library), into: store, root: "library")
        #expect(again.asked.isEmpty)
        #expect(library.decoded.isEmpty)
        #expect(second == first)
    }

    @Test("new pixels or a new revision are looked at again")
    func lookedAtAgain() throws {
        let library = MarkedLibrary(count: 160)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        let first = try builder(FakeAssessor()).build(from: source(library), into: store, root: "library")
        let edited = MarkedLibrary.index(of: first.entries[0].photoID)
        library.edit(edited)
        let afterEdit = FakeAssessor()
        _ = try builder(afterEdit).build(from: source(library), into: store, root: "library")
        #expect(afterEdit.asked == [edited])

        let revised = FakeAssessor(revision: "fake-2")
        let manifest = try builder(revised).build(from: source(library), into: store, root: "library")
        #expect(Set(revised.asked) == indices(manifest.entries.map(\.id)))
        #expect(manifest.assessments.allSatisfy { $0.revision == "fake-2" })
    }

    @Test("an index from before is read again once, and judged")
    func indexFromBefore() throws {
        let library = MarkedLibrary(count: 160)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        let before = try builder(nil).build(from: source(library, quality: nil), into: store, root: "library")
        #expect(before.assessments.isEmpty)
        let utility = Set(indices(before.entries.map(\.id)).prefix(5))
        let assessor = FakeAssessor(utility: utility)
        let after = try builder(assessor).build(from: source(library), into: store, root: "library")
        #expect(Set(assessor.asked).isSuperset(of: indices(before.entries.map(\.id))))
        #expect(indices(after.entries.map(\.id)).isDisjoint(with: utility))
        #expect(after.entries.count == 40)
    }

    @Test("photographs Photos has not scored are judged by Vision against their month's bar")
    func weakByVision() throws {
        let library = MarkedLibrary(count: 160)
        // Photos scored the even ones, 0.3 to 0.9; Vision is asked about
        // the odd ones, and gives the photographs from 100 on a dreadful score.
        var scores: [Int: Double] = [:]
        for index in stride(from: 0, to: 160, by: 2) { scores[index] = 0.3 + 0.6 * Double(index) / 160 }
        var vision: [Int: Float] = [:]
        for index in stride(from: 1, to: 160, by: 2) { vision[index] = index >= 100 ? -0.9 : 0.8 }
        let assessor = FakeAssessor(scores: vision)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder(assessor).build(
            from: source(library, quality: FakeQualities(scores: scores)), into: PhotoIndexStore(directory: index),
            root: "library"
        )
        let ready = indices(manifest.entries.map(\.id))
        #expect(ready.count == 40)
        #expect(ready.filter { $0 % 2 == 1 && $0 >= 100 }.isEmpty)
        #expect(!ready.filter { $0 % 2 == 1 }.isEmpty)
        #expect(assessor.scored.allSatisfy { $0 % 2 == 1 }, "a photograph Photos scored was scored again")
        // The worst tenth of those Photos scored never reached Vision.
        #expect(!ready.contains(0) && !assessor.asked.contains(0))
    }

    @Test("a photograph Photos scores later is not looked at again")
    func scoredLater() throws {
        let library = MarkedLibrary(count: 160)
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        let first = try builder(FakeAssessor()).build(from: source(library), into: store, root: "library")
        var scores: [Int: Double] = [:]
        for index in 0..<160 { scores[index] = 0.9 }
        let later = FakeAssessor()
        _ = try builder(later).build(
            from: source(library, quality: FakeQualities(scores: scores)), into: store, root: "library"
        )
        #expect(later.asked.isEmpty)
        #expect(!first.assessments.isEmpty)
    }

    @Test("screenshots are never decoded")
    func screenshots() throws {
        let library = MarkedLibrary(count: 160)
        let shots = Set(stride(from: 0, to: 160, by: 4))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder(FakeAssessor()).build(
            from: source(library, quality: FakeQualities(screenshots: shots)), into: PhotoIndexStore(directory: index),
            root: "library"
        )
        #expect(manifest.entries.count == 40)
        #expect(indices(library.decoded).isDisjoint(with: shots))
    }

    @Test("a photograph Vision cannot read stays, unjudged")
    func visionFails() throws {
        let library = MarkedLibrary(count: 160)
        let assessor = FakeAssessor(failing: Set(0..<160))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let manifest = try builder(assessor).build(from: source(library), into: PhotoIndexStore(directory: index), root: "library")
        #expect(manifest.entries.count == 40)
        #expect(manifest.assessments.isEmpty)
    }

    @Test("without culling Vision is never asked and the manifest is as it was")
    func withoutCulling() throws {
        let library = MarkedLibrary(count: 160)
        let plain = temporaryDirectory(), judged = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: judged)
        }
        let assessor = FakeAssessor(utility: Set(0..<160))
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let without = try builder(nil).build(
            from: source(library, quality: nil), into: PhotoIndexStore(directory: plain), root: "library", now: now
        )
        let unused = try builder(assessor).build(
            from: source(library, quality: nil), into: PhotoIndexStore(directory: judged), root: "library", now: now
        )
        #expect(assessor.asked.isEmpty)
        #expect(unused == without)
        let bytes = { (url: URL) in try Data(contentsOf: url.appendingPathComponent("manifest.json")) }
        #expect(try bytes(plain) == bytes(judged))
        #expect(try !String(decoding: bytes(plain), as: UTF8.self).contains("assessments"))
    }

    @Test("turned off, the assessments stay; turned on again, nothing is looked at twice")
    func offAndOn() throws {
        let library = MarkedLibrary(count: 160)
        let utility = Set(stride(from: 0, to: 160, by: 3))
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        let on = try builder(FakeAssessor(utility: utility)).build(from: source(library), into: store, root: "library")
        let off = try builder(nil).build(from: source(library, quality: nil), into: store, root: "library")
        #expect(off.assessments == on.assessments)
        let again = FakeAssessor(utility: utility)
        let back = try builder(again).build(from: source(library), into: store, root: "library")
        #expect(indices(back.entries.map(\.id)).isDisjoint(with: utility))
        #expect(again.asked.isEmpty)
    }
}

@Suite("Vision score map")
struct VisionScoreMapTests {
    @Test("it is monotone and stays on Photos' scale")
    func monotone() {
        var last = -Double.infinity
        for step in 0...400 {
            let mapped = VisionScoreMap.photosScore(forVision: -1 + Double(step) / 200)
            #expect(mapped >= last)
            #expect((0...1).contains(mapped))
            last = mapped
        }
    }

    @Test("it goes through the points spike 5 measured")
    func points() {
        let expected: [(Double, Double)] = [(0, 0.22), (0.4, 0.42), (0.6, 0.62), (-0.4, 0.08)]
        for (vision, photos) in expected {
            let mapped = VisionScoreMap.photosScore(forVision: vision)
            #expect(abs(mapped - photos) < 0.015, "\(vision) -> \(mapped), spike 5 had \(photos)")
        }
        #expect(VisionScoreMap.photosScore(forVision: -1) == 0)
    }
}
