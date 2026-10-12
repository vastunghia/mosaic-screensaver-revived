import Foundation

/// How many close-ups have been fetched from iCloud lately, so that the shelf
/// never fetches more than a fixed number in a day or a week (SPEC § 5).
///
/// A fetch costs space in the Photos library — about 2 MB each, measured on
/// an optimised library on 2026-10-12 — that Photos frees only when it
/// chooses. The caps hold whatever changes the subjects: a new seed, albums
/// chosen again, a bug. Every request is counted, whether it succeeds or not,
/// since a failed one may have fetched something too.
public struct DownloadLedger: Codable, Equatable, Sendable {
    /// One full set of subjects of a 2048-photograph subset.
    public static let standardDailyLimit = 128
    /// Two: a new set of subjects in a week, and what Photos took back.
    public static let standardWeeklyLimit = 256

    private static let day: TimeInterval = 24 * 60 * 60
    private static let week: TimeInterval = 7 * day

    /// When each fetch was asked for, the last week's only.
    public private(set) var requests: [Date]

    public init(requests: [Date] = []) {
        self.requests = requests
    }

    /// How many more may be fetched at `now`.
    public func remaining(
        at now: Date, daily: Int = Self.standardDailyLimit, weekly: Int = Self.standardWeeklyLimit
    ) -> Int {
        let lastDay = requests.filter { now.timeIntervalSince($0) < Self.day }.count
        return max(0, min(daily - lastDay, weekly - lastWeek(at: now)))
    }

    /// How many were asked for in the week before `now`.
    public func lastWeek(at now: Date) -> Int {
        requests.filter { now.timeIntervalSince($0) < Self.week }.count
    }

    public mutating func record(at now: Date) {
        requests = requests.filter { now.timeIntervalSince($0) < Self.week } + [now]
    }

    /// An absent or unreadable ledger is an empty one: the worst that costs
    /// is one more day's fetches.
    public static func load(from url: URL) -> DownloadLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(DownloadLedger.self, from: data) else {
            return DownloadLedger()
        }
        return ledger
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
