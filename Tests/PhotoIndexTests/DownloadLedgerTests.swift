import Foundation
import Testing
@testable import PhotoIndex

@Suite("Download ledger")
struct DownloadLedgerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let hour: TimeInterval = 3600

    @Test("the day's cap and the week's both hold, and old requests drop out")
    func caps() {
        var ledger = DownloadLedger()
        #expect(ledger.remaining(at: now, daily: 3, weekly: 5) == 3)
        for offset in 0..<3 { ledger.record(at: now.addingTimeInterval(Double(offset))) }
        #expect(ledger.remaining(at: now.addingTimeInterval(hour), daily: 3, weekly: 5) == 0)

        let tomorrow = now.addingTimeInterval(25 * hour)
        #expect(ledger.remaining(at: tomorrow, daily: 3, weekly: 5) == 2, "the week's cap is the tighter")
        ledger.record(at: tomorrow)
        ledger.record(at: tomorrow)
        #expect(ledger.remaining(at: tomorrow.addingTimeInterval(25 * hour), daily: 3, weekly: 5) == 0)

        let nextWeek = now.addingTimeInterval(7 * 24 * hour + 10)
        #expect(ledger.remaining(at: nextWeek, daily: 3, weekly: 5) == 3)
        ledger.record(at: nextWeek)
        #expect(ledger.requests.count == 3, "the first day's are forgotten")
    }

    @Test("one given up on gives its place back, up to a cap of its own for the day")
    func abandoned() {
        var ledger = DownloadLedger()
        for offset in 0..<3 { ledger.record(at: now.addingTimeInterval(Double(offset))) }
        ledger.abandon(requestedAt: now.addingTimeInterval(1), at: now.addingTimeInterval(20))
        #expect(ledger.requests.count == 2 && ledger.lastWeek(at: now.addingTimeInterval(hour)) == 2)
        #expect(ledger.remaining(at: now.addingTimeInterval(hour), daily: 3, weekly: 5, abandonedDaily: 2) == 1)
        #expect(ledger.remaining(at: now.addingTimeInterval(hour), daily: 3, weekly: 5, abandonedDaily: 1) == 0)

        ledger.abandon(requestedAt: now, at: now.addingTimeInterval(30))
        #expect(ledger.remaining(at: now.addingTimeInterval(hour), daily: 3, weekly: 5, abandonedDaily: 2) == 0,
                "two given up on: the day's cap for those is reached")
        #expect(ledger.remaining(at: now.addingTimeInterval(25 * hour), daily: 3, weekly: 5, abandonedDaily: 2) == 3)
    }

    @Test("a ledger from before requests could be given up on still loads")
    func older() throws {
        let data = Data(#"{"requests":[800000000]}"#.utf8)
        let ledger = try JSONDecoder().decode(DownloadLedger.self, from: data)
        #expect(ledger.requests.count == 1 && ledger.abandoned.isEmpty)
    }

    @Test("saved and loaded whole; a missing or broken file is an empty ledger")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-ledger-\(UUID().uuidString)/ledger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(DownloadLedger.load(from: url) == DownloadLedger())

        var ledger = DownloadLedger()
        ledger.record(at: now)
        try ledger.save(to: url)
        #expect(DownloadLedger.load(from: url) == ledger)

        try Data("not json".utf8).write(to: url)
        #expect(DownloadLedger.load(from: url) == DownloadLedger())
    }
}
