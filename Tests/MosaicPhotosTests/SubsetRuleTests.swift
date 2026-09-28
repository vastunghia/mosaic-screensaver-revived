import Foundation
import MosaicCore
import Testing
@testable import MosaicPhotos

@Suite("Subset rule")
struct SubsetRuleTests {
    /// `count` photographs, one a day from 2020-01-01, named so that
    /// identifier order and date order disagree.
    private func library(_ count: Int, undated: Int = 0) -> [PhotoDescriptor] {
        let start = Date(timeIntervalSinceReferenceDate: 600_000_000)
        var photos = (0..<count).map { day in
            PhotoDescriptor(
                id: PhotoID(String(format: "%05d/L0/001", (day * 7919) % 100_000)),
                versionToken: "1",
                creationDate: start.addingTimeInterval(Double(day) * 86_400)
            )
        }
        photos += (0..<undated).map { PhotoDescriptor(id: PhotoID("undated-\($0)"), versionToken: "1") }
        return photos
    }

    @Test("every rule takes exactly N, sorted by identifier, and all when there are fewer")
    func sizesAndOrder() {
        let photos = library(500, undated: 20)
        for rule in SubsetRule.allCases {
            let chosen = rule.choose(from: photos, count: 100, seed: 7)
            #expect(chosen.count == 100, "\(rule)")
            #expect(Set(chosen.map(\.id)).count == 100, "\(rule): no photograph twice")
            #expect(chosen.map(\.id.rawValue) == chosen.map(\.id.rawValue).sorted(), "\(rule)")
            #expect(rule.choose(from: photos, count: 1000, seed: 7).count == photos.count, "\(rule)")
        }
    }

    @Test("recent takes the newest, and undated photographs last")
    func recent() {
        let photos = library(500, undated: 20)
        let chosen = SubsetRule.recent.choose(from: photos, count: 50, seed: 0)
        let newest = photos.filter { $0.creationDate != nil }
            .sorted { $0.creationDate! > $1.creationDate! }.prefix(50)
        #expect(Set(chosen.map(\.id)) == Set(newest.map(\.id)))
    }

    @Test("random is a function of the seed, and a new photograph displaces at most one")
    func randomIsStable() {
        let photos = library(2000)
        let a = SubsetRule.random.choose(from: photos, count: 300, seed: 42)
        #expect(a == SubsetRule.random.choose(from: photos.shuffled(), count: 300, seed: 42))
        #expect(a != SubsetRule.random.choose(from: photos, count: 300, seed: 43))

        let grown = photos + [PhotoDescriptor(id: PhotoID("new"), versionToken: "1", creationDate: Date())]
        let b = SubsetRule.random.choose(from: grown, count: 300, seed: 42)
        #expect(Set(a.map(\.id)).subtracting(b.map(\.id)).count <= 1)
    }

    @Test("uniform in time spreads over the whole span, gap or no gap")
    func uniformInTime() {
        // Two years of daily photographs with the whole second half of the
        // first year missing, and a burst of 1000 on one day at the end.
        let start = Date(timeIntervalSinceReferenceDate: 600_000_000)
        var photos = library(730).filter {
            let day = $0.creationDate!.timeIntervalSince(start) / 86_400
            return !(182..<365).contains(day)
        }
        photos += (0..<1000).map {
            PhotoDescriptor(id: PhotoID("burst-\($0)"), versionToken: "1",
                            creationDate: start.addingTimeInterval(729 * 86_400 + Double($0)))
        }

        let chosen = SubsetRule.uniformInTime.choose(from: photos, count: 73, seed: 0)
        let burst = chosen.filter { $0.id.rawValue.hasPrefix("burst-") }.count
        // Evenly in time, the last day is 1/730 of the span: a photograph or two,
        // not the 57% that the burst is of the library.
        #expect(burst <= 2)
        // One moment every 10 days. The 18 before the gap stay there; the 18
        // inside it split between its two borders, and the far border is in
        // the second year: 18 + 9.
        let firstYear = chosen.filter { $0.creationDate!.timeIntervalSince(start) < 365 * 86_400 }.count
        #expect((25...29).contains(firstYear))
    }

    @Test("the subset source passes only the chosen photographs")
    func subsetSource() throws {
        let base = SyntheticPhotoSource(count: 40)
        let source = SubsetPhotoSource(base, rule: .random, count: 10, seed: 1)
        let chosen = try source.photos()
        #expect(chosen.count == 10)
        #expect(Set(chosen.map(\.id)).isSubset(of: Set(try base.photos().map(\.id))))
    }
}
