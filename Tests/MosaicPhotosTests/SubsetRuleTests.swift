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

    /// What filling a subset to its target rests on (SPEC § 5): taking
    /// photographs out of the library never pushes out a chosen one that
    /// stayed. Without it every round of the fill would throw away photographs
    /// indexed in the round before.
    @Test("removing photographs never pushes out a chosen one that stayed")
    func monotone() {
        var rng = SplitMix64(seed: 11)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for trial in 0..<200 {
            // Months of very different sizes, some undated photographs.
            var photos: [PhotoDescriptor] = []
            for month in 0..<Int(rng.next() % 30 + 1) {
                for index in 0..<Int(rng.next() % 40) {
                    let date = calendar.date(from: DateComponents(
                        year: 2000 + month / 12, month: 1 + month % 12, day: 1 + index % 28, second: index
                    ))!
                    photos.append(PhotoDescriptor(
                        id: PhotoID("t\(trial)-m\(month)-\(index)"), versionToken: "1", creationDate: date
                    ))
                }
            }
            photos += (0..<Int(rng.next() % 10)).map {
                PhotoDescriptor(id: PhotoID("t\(trial)-u\($0)"), versionToken: "1")
            }
            let count = Int(rng.next() % UInt64(max(photos.count, 1))) + 1
            let removedShare = rng.next() % 90 + 5
            let removed = Set(photos.map(\.id).filter { _ in rng.next() % 100 < removedShare })

            for rule in SubsetRule.allCases {
                let before = Set(rule.choose(from: photos, count: count, seed: 5).map(\.id))
                let after = Set(rule.choose(from: photos.filter { !removed.contains($0.id) }, count: count, seed: 5).map(\.id))
                let lost = before.subtracting(removed).subtracting(after)
                #expect(lost.isEmpty, "\(rule), trial \(trial): \(lost.count) chosen photographs pushed out")
            }
        }
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
