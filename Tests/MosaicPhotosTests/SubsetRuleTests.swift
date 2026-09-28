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

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func month(_ photo: PhotoDescriptor) -> Int {
            let parts = calendar.dateComponents([.year, .month], from: photo.creationDate!)
            return parts.year! * 12 + parts.month!
        }

        let chosen = SubsetRule.uniformInTime.choose(from: photos, count: 73, seed: 0)
        let perMonth = Dictionary(grouping: chosen, by: month).mapValues(\.count)
        let monthsWithPhotographs = Set(photos.map(month))

        // Every month with photographs gets a share, and the shares differ by
        // at most one: the burst's month is one month like the others, not the
        // 57% that the burst is of the library, and the gap is not handed to
        // its borders.
        #expect(Set(perMonth.keys) == monthsWithPhotographs)
        #expect(perMonth.values.max()! - perMonth.values.min()! <= 1)
        let burst = chosen.filter { $0.id.rawValue.hasPrefix("burst-") }.count
        #expect(burst <= perMonth.values.max()!)
    }

    @Test("uniform in time gives a sparse month everything it has, and the rest to the others")
    func uniformInTimeWaterFills() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // January: 2 photographs. February and March: 100 each.
        let photos = (0..<202).map { index in
            let month = index < 2 ? 1 : (index < 102 ? 2 : 3)
            let date = calendar.date(from: DateComponents(
                year: 2020, month: month, day: 1 + index % 28, second: index
            ))!
            return PhotoDescriptor(id: PhotoID("p\(index)"), versionToken: "1", creationDate: date)
        }
        let chosen = SubsetRule.uniformInTime.choose(from: photos, count: 60, seed: 3)
        let ids = Set(chosen.map(\.id.rawValue))
        #expect(ids.contains("p0") && ids.contains("p1"))
        let february = chosen.filter { (2..<102).contains(Int($0.id.rawValue.dropFirst())!) }.count
        #expect(february == 29)
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
