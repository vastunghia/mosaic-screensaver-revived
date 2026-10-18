import Foundation

/// How many close-ups have been fetched from iCloud lately, so that the shelf
/// never fetches more than a fixed number in a day or a week (SPEC § 5).
///
/// A fetch costs space in the Photos library — 0.85 MB each, 106 MB for 126,
/// measured on an optimised library on 2026-10-13 — that Photos frees only
/// when it chooses. The caps hold whatever changes the subjects: a new seed,
/// albums chosen again, a bug. Every request is counted before it is made,
/// whether it succeeds or not, since a failed one may have fetched something
/// too.
///
/// Except one given up on as too slow: it is moved to `abandoned`, which has
/// a cap of its own. None of the 32 given up on in three runs on 2026-10-13
/// was in the library a minute later, and the library grew by what the others
/// account for; but one that is always too slow, asked again whenever the
/// library changes, would cost the network without end.
///
/// So each photograph given up on is remembered too, by run: one still not
/// here at the end of `standardRunsBeforeRest` runs rests for
/// `standardRest`, neither asked for nor a subject, and another takes its
/// place. Of the photographs given up on in the runs of 2026-10-13, eight
/// came in at the third request and one had not after three.
public struct DownloadLedger: Codable, Equatable, Sendable {
    /// One full set of subjects of a 2048-photograph subset, and the copies
    /// for the anchor's ring with it: 122 and 62 on an optimised profile on
    /// 2026-10-15, so 184 (128 a day until then; Sergio).
    public static let standardDailyLimit = 256
    /// Two such days: a new set in a week, and what Photos took back.
    public static let standardWeeklyLimit = 512
    /// Requests given up on in a day.
    public static let standardDailyAbandonedLimit = 128

    /// Runs that end with a photograph given up on before it rests.
    public static let standardRunsBeforeRest = 3
    public static let standardRest: TimeInterval = week

    private static let day: TimeInterval = 24 * 60 * 60
    private static let week: TimeInterval = 7 * day

    /// A photograph given up on: in how many runs since it last came in or
    /// last rested, until when it rests, and when it was last given up on,
    /// in a stall too: those are asked for last.
    public struct SlowPhoto: Codable, Equatable, Sendable {
        public var runs: Int
        public var restingUntil: Date?
        public var lastGivenUp: Date?

        public init(runs: Int = 0, restingUntil: Date? = nil, lastGivenUp: Date? = nil) {
            self.runs = runs
            self.restingUntil = restingUntil
            self.lastGivenUp = lastGivenUp
        }
    }

    /// When each fetch was asked for, the last week's only.
    public private(set) var requests: [Date]
    /// When each request given up on was given up, the last day's only.
    public private(set) var abandoned: [Date]
    /// The photographs given up on, by index entry id.
    public private(set) var slow: [String: SlowPhoto]

    public init(requests: [Date] = [], abandoned: [Date] = [], slow: [String: SlowPhoto] = [:]) {
        self.requests = requests
        self.abandoned = abandoned
        self.slow = slow
    }

    /// A ledger written before requests could be given up on has none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decode([Date].self, forKey: .requests)
        abandoned = try container.decodeIfPresent([Date].self, forKey: .abandoned) ?? []
        slow = try container.decodeIfPresent([String: SlowPhoto].self, forKey: .slow) ?? [:]
    }

    /// How many more may be fetched at `now`: none once the day's given-up
    /// requests reach their cap.
    public func remaining(
        at now: Date, daily: Int = Self.standardDailyLimit, weekly: Int = Self.standardWeeklyLimit,
        abandonedDaily: Int = Self.standardDailyAbandonedLimit
    ) -> Int {
        let abandonedLastDay = abandoned.filter { now.timeIntervalSince($0) < Self.day }.count
        guard abandonedLastDay < abandonedDaily else { return 0 }
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

    /// The request recorded at `requested` was given up on at `now`: it no
    /// longer counts as a fetch, but as one given up on.
    public mutating func abandon(requestedAt requested: Date, at now: Date) {
        if let index = requests.lastIndex(of: requested) { requests.remove(at: index) }
        abandoned = abandoned.filter { now.timeIntervalSince($0) < Self.day } + [now]
    }

    /// A run ended with `ids` given up on and still not here: each counts one
    /// more run, and rests from `now` once it reaches `runsBeforeRest`.
    ///
    /// `stalled` were given up on while iCloud did not answer at all: they
    /// count no run, but are asked for last next time, so that a run does
    /// not stop on the same ones again.
    public mutating func gaveUp(
        on ids: some Sequence<String>, stalled: some Sequence<String> = [String](), at now: Date,
        runsBeforeRest: Int = Self.standardRunsBeforeRest, rest: TimeInterval = Self.standardRest
    ) {
        slow = slow.filter { _, photo in
            photo.runs > 0 || photo.restingUntil.map { $0 > now } == true
                || photo.lastGivenUp.map { now.timeIntervalSince($0) < Self.week } == true
        }
        for id in ids {
            var photo = slow[id] ?? SlowPhoto()
            photo.runs += 1
            photo.lastGivenUp = now
            if photo.runs >= runsBeforeRest {
                photo = SlowPhoto(runs: 0, restingUntil: now.addingTimeInterval(rest), lastGivenUp: now)
            }
            slow[id] = photo
        }
        for id in stalled {
            slow[id, default: SlowPhoto()].lastGivenUp = now
        }
    }

    /// `ids` in the order to ask for them: those never given up on first, in
    /// their order, then the others from the longest ago given up on.
    public func ordered(_ ids: [String]) -> [String] {
        let fresh = ids.filter { slow[$0]?.lastGivenUp == nil }
        let given = ids.compactMap { id in slow[id]?.lastGivenUp.map { (id, $0) } }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
        return fresh + given
    }

    /// The user reset the caps, having confirmed what it costs (SPEC § 5):
    /// what was asked for so far no longer counts, and the caps hold again
    /// from now. Photographs resting go on resting: that is about iCloud,
    /// not about the user's disk.
    public mutating func resetLimits() {
        requests = []
        abandoned = []
    }

    /// `id` came in: whatever it cost before is forgotten.
    public mutating func arrived(_ id: String) {
        slow[id] = nil
    }

    /// The photographs resting at `now`: not to be asked for, nor subjects.
    public func resting(at now: Date) -> Set<String> {
        Set(slow.filter { _, photo in photo.restingUntil.map { $0 > now } == true }.keys)
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
