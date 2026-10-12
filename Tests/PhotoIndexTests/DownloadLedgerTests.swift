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
