import Foundation
import MosaicCore
import Testing
@testable import MosaicPhotos

@Suite("Culling")
struct CullingTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `count` photographs taken in `month` of 2020 (1-based), named `prefix`-n.
    private func month(_ month: Int, _ count: Int, prefix: String) -> [PhotoDescriptor] {
        (0..<count).map { index in
            PhotoDescriptor(
                id: PhotoID("\(prefix)-\(index)"), versionToken: "1",
                creationDate: Self.utc.date(from: DateComponents(year: 2020, month: month, day: 1 + index % 28, hour: index % 24))!
            )
        }
    }

    /// Scores 0, 1/n, 2/n… in identifier order, so the worst are known.
    private func ramp(_ photos: [PhotoDescriptor], from low: Double = 0, to high: Double = 1) -> [PhotoID: PhotoQuality] {
        var qualities: [PhotoID: PhotoQuality] = [:]
        for (index, photo) in photos.enumerated() {
            qualities[photo.id] = PhotoQuality(score: low + (high - low) * Double(index) / Double(photos.count))
        }
        return qualities
    }

    @Test("the worst tenth of each month goes, with uniform in time")
    func byMonth() {
        // A dim month and a bright one: each loses its own worst tenth, so the
        // dim month keeps its share of the subset.
        let dim = month(1, 100, prefix: "dim")
        let bright = month(2, 100, prefix: "bright")
        let qualities = ramp(dim, from: 0, to: 0.3).merging(ramp(bright, from: 0.6, to: 0.9)) { a, _ in a }
        let culling = Culling(library: dim + bright, qualities: qualities, rule: .uniformInTime)

        #expect(culling.weak == 20)
        let kept = Set(culling.kept.map(\.id.rawValue))
        #expect(!kept.contains("dim-9") && kept.contains("dim-10"))
        #expect(!kept.contains("bright-9") && kept.contains("bright-10"))
        #expect(culling.bar(for: dim[0]) < culling.bar(for: bright[0]))
    }

    @Test("with the other rules the worst tenth of the whole library goes")
    func wholeLibrary() {
        let dim = month(1, 100, prefix: "dim")
        let bright = month(2, 100, prefix: "bright")
        let qualities = ramp(dim, from: 0, to: 0.3).merging(ramp(bright, from: 0.6, to: 0.9)) { a, _ in a }
        for rule in [SubsetRule.recent, .random] {
            let culling = Culling(library: dim + bright, qualities: qualities, rule: rule)
            #expect(culling.weak == 20, "\(rule)")
            #expect(culling.kept.allSatisfy { !$0.id.rawValue.hasPrefix("dim-") || Int($0.id.rawValue.dropFirst(4))! >= 20 })
            #expect(culling.bar(for: dim[0]) == culling.bar(for: bright[0]))
        }
    }

    @Test("photographs without a score stay, and do not move the bar")
    func unscored() {
        let scored = month(1, 100, prefix: "s")
        let unscored = month(1, 300, prefix: "u")
        let alone = Culling(library: scored, qualities: ramp(scored), rule: .uniformInTime)
        let mixed = Culling(library: scored + unscored, qualities: ramp(scored), rule: .uniformInTime)
        #expect(mixed.weak == alone.weak)
        #expect(mixed.bar(for: unscored[0]) == alone.bar(for: scored[0]))
        #expect(Set(unscored.map(\.id)).isSubset(of: Set(mixed.kept.map(\.id))))
        #expect(!mixed.hasScore(unscored[0].id) && mixed.hasScore(scored[0].id))
        #expect(mixed.scored == 100)
    }

    @Test("screenshots go, whatever their score, and do not count towards the bar")
    func screenshots() {
        let photos = month(1, 100, prefix: "p")
        var qualities = ramp(photos)
        for photo in photos.prefix(30) { qualities[photo.id]?.isScreenshot = true }
        let shot = PhotoDescriptor(id: PhotoID("shot"), versionToken: "1")
        qualities[shot.id] = PhotoQuality(isScreenshot: true)
        let culling = Culling(library: photos + [shot], qualities: qualities, rule: .random)
        #expect(culling.screenshots == 31)
        #expect(!culling.kept.contains(shot))
        // The 70 left, of 0.30…0.99: the worst 7 go.
        #expect(culling.weak == 7)
        #expect(culling.bar(for: photos[50]) == qualities[photos[37].id]?.score)
    }

    @Test("ties at the bar stay")
    func ties() {
        let photos = month(1, 100, prefix: "p")
        var qualities: [PhotoID: PhotoQuality] = [:]
        for (index, photo) in photos.enumerated() { qualities[photo.id] = PhotoQuality(score: index < 40 ? 0 : 0.5) }
        let culling = Culling(library: photos, qualities: qualities, rule: .random)
        // 0 is a real score, the bottom of the scale; a bar of 0 leaves nothing below it.
        #expect(culling.libraryBar == 0)
        #expect(culling.weak == 0)
    }

    @Test("a small month takes the library's bar, and a small library the reference")
    func fallbacks() {
        let big = month(1, 100, prefix: "big")
        let small = month(2, 10, prefix: "small")
        var qualities = ramp(big, from: 0.5, to: 1)
        for (index, photo) in small.enumerated() { qualities[photo.id] = PhotoQuality(score: 0.5 + Double(index) / 100) }
        let culling = Culling(library: big + small, qualities: qualities, rule: .uniformInTime)
        #expect(culling.bar(for: small[0]) == culling.libraryBar)
        #expect(culling.bar(for: big[0]) != culling.libraryBar)
        // The small month's scores, 0.50…0.59, judged by the library's bar.
        let keptSmall = culling.kept.filter { $0.id.rawValue.hasPrefix("small") }
        #expect(keptSmall.count == small.filter { qualities[$0.id]!.score! >= culling.libraryBar }.count)

        let undated = PhotoDescriptor(id: PhotoID("undated"), versionToken: "1")
        #expect(culling.bar(for: undated) == culling.libraryBar)

        let few = Culling(library: small, qualities: qualities, rule: .uniformInTime)
        #expect(few.libraryBar == Culling.referenceBar)
        let none = Culling(library: big, qualities: [:], rule: .uniformInTime)
        #expect(none.kept == big && none.weak == 0 && none.screenshots == 0)
        #expect(none.bar(for: big[0]) == Culling.referenceBar)
    }

    @Test("a source without qualities chooses as it always did")
    func noQualities() throws {
        let base = SyntheticPhotoSource(count: 200)
        let plain = SubsetPhotoSource(base, rule: .uniformInTime, count: 50, seed: 3)
        let culled = SubsetPhotoSource(base, rule: .uniformInTime, count: 50, seed: 3, quality: NoPhotoQuality())
        #expect(try plain.photos() == culled.photos())
        #expect(plain.cull(try plain.library()) == nil)
        #expect(culled.choice == plain.choice)
    }

    @Test("a source with qualities never chooses what it culls")
    func sourceCulls() throws {
        struct Ramp: PhotoQualitySource {
            func qualities(of photos: [PhotoDescriptor]) -> [PhotoID: PhotoQuality] {
                var qualities: [PhotoID: PhotoQuality] = [:]
                for photo in photos { qualities[photo.id] = PhotoQuality(score: Double(SubsetRule.rank(of: photo.id, seed: 0) % 256) / 256) }
                return qualities
            }
        }
        let base = SyntheticPhotoSource(count: 300)
        let source = SubsetPhotoSource(base, rule: .random, count: 250, seed: 1, quality: Ramp())
        let culling = try #require(source.cull(try source.library()))
        let chosen = try source.photos()
        #expect(chosen.count == 250)
        let culled = Set(try source.library().map(\.id)).subtracting(culling.kept.map(\.id))
        #expect(!culled.isEmpty)
        #expect(culled.isDisjoint(with: chosen.map(\.id)))
    }

    /// What the fill rests on, with culling in front: Vision's rejects taken
    /// out of a culled library never push out a chosen photograph that stayed.
    @Test("leaving out Vision's rejects never pushes out a chosen one that stayed")
    func monotoneAfterCulling() {
        var rng = SplitMix64(seed: 23)
        for trial in 0..<100 {
            var photos: [PhotoDescriptor] = []
            var qualities: [PhotoID: PhotoQuality] = [:]
            for monthIndex in 0..<Int(rng.next() % 24 + 1) {
                for photo in month(1 + monthIndex % 12, Int(rng.next() % 60), prefix: "t\(trial)-m\(monthIndex)") {
                    let date = photo.creationDate!.addingTimeInterval(Double(monthIndex / 12) * 366 * 86_400)
                    let moved = PhotoDescriptor(id: photo.id, versionToken: "1", creationDate: date)
                    photos.append(moved)
                    switch rng.next() % 4 {
                    case 0: break
                    case 1: qualities[moved.id] = PhotoQuality(isScreenshot: rng.next() % 10 == 0)
                    default: qualities[moved.id] = PhotoQuality(score: Double(rng.next() % 1000) / 1000)
                    }
                }
            }
            let culling = Culling(library: photos, qualities: qualities, rule: .uniformInTime)
            let count = Int(rng.next() % UInt64(max(culling.kept.count, 1))) + 1
            let rejected = Set(culling.kept.map(\.id).filter { _ in rng.next() % 100 < 15 })
            let before = Set(SubsetRule.uniformInTime.choose(from: culling.kept, count: count, seed: 5).map(\.id))
            let after = Set(SubsetRule.uniformInTime.choose(
                from: culling.kept.filter { !rejected.contains($0.id) }, count: count, seed: 5
            ).map(\.id))
            let lost = before.subtracting(rejected).subtracting(after)
            #expect(lost.isEmpty, "trial \(trial): \(lost.count) chosen photographs pushed out")
        }
    }
}
