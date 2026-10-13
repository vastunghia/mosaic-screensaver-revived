import CoreGraphics
import Foundation
import MosaicCore

/// Which `N` photographs of a library get indexed (SPEC § 5, question 8.6).
///
/// A library can hold 54,000 photographs and the index holds a few thousand,
/// so something has to choose, and what it chooses is visible on screen. Which
/// rule is the default is decided by looking at a specimen, not here; this is
/// only the three candidates, made exact.
///
/// Every rule must be **stable**: the same library gives the same subset, and a
/// library that gains one photograph gives nearly the same subset. The index is
/// built incrementally, so a subset that reshuffles is a subset that has to be
/// indexed again from the start.
public enum SubsetRule: String, CaseIterable, Sendable {
    /// The most recently taken. Coherent, and the most monotonous.
    case recent
    /// A sample of the whole library. Stable because each photograph's place is
    /// a hash of its identifier and a seed kept in the preferences, not a
    /// shuffle: a new photograph displaces at most one other, where a shuffle
    /// would move everything.
    case random
    /// Evenly spread over the time the library covers: every calendar month
    /// that has photographs gets the same share, a month with fewer than its
    /// share gives all it has, and what it could not give is shared among the
    /// others. Within a month the choice is `random`'s, so a new photograph
    /// disturbs at most its own month.
    ///
    /// The first version aimed at `N` equally spaced moments and took the
    /// nearest photograph to each. On a real library of 54,000 it gave a
    /// quarter of the subset to 2004: the library starts in 1982 with a few
    /// dozen scans, and every moment of those twenty near-empty years fell to
    /// the first year with photographs in it.
    case uniformInTime

    /// `count` of `photos`, sorted by identifier. All of them when there are
    /// not more than `count`.
    public func choose(from photos: [PhotoDescriptor], count: Int, seed: UInt64) -> [PhotoDescriptor] {
        guard photos.count > count else { return photos.sorted(by: Self.byIdentifier) }
        guard count > 0 else { return [] }

        let chosen: [PhotoDescriptor]
        switch self {
        case .recent:
            chosen = Array(photos.sorted(by: Self.newestFirst).prefix(count))
        case .random:
            chosen = Array(
                photos
                    .map { (rank: Self.rank(of: $0.id, seed: seed), photo: $0) }
                    .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : Self.byIdentifier($0.photo, $1.photo) }
                    .prefix(count)
                    .map(\.photo)
            )
        case .uniformInTime:
            chosen = Self.spreadOverTime(photos, count: count, seed: seed)
        }
        return chosen.sorted(by: Self.byIdentifier)
    }

    // MARK: -

    static func byIdentifier(_ a: PhotoDescriptor, _ b: PhotoDescriptor) -> Bool {
        a.id.rawValue < b.id.rawValue
    }

    /// Newest first; undated photographs after every dated one.
    static func newestFirst(_ a: PhotoDescriptor, _ b: PhotoDescriptor) -> Bool {
        switch (a.creationDate, b.creationDate) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return byIdentifier(a, b)
        }
    }

    /// A position for `id` that depends on nothing but `id` and `seed`: FNV-1a
    /// over the UTF-8 bytes, stirred by SplitMix64. Not `hashValue`, which
    /// changes from one process to the next.
    static func rank(of id: PhotoID, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        var rng = SplitMix64(seed: hash ^ seed)
        return rng.next()
    }

    /// A month's place in the order the remainder is handed out in, made like
    /// a photograph's.
    static func rank(ofMonth key: Int, seed: UInt64) -> UInt64 {
        rank(of: PhotoID("month-\(key)"), seed: seed)
    }

    /// Equal shares per calendar month (UTC, so the answer does not depend on
    /// the Mac's time zone), filled like water: every month gives at most what
    /// it has, and the share is the level at which the months together reach
    /// `count`. Undated photographs are drawn on only if the dated ones run
    /// out, by `random`.
    static func spreadOverTime(_ photos: [PhotoDescriptor], count: Int, seed: UInt64) -> [PhotoDescriptor] {
        let undated = photos.filter { $0.creationDate == nil }
        let datedCount = photos.count - undated.count
        guard datedCount > count else {
            let dated = photos.filter { $0.creationDate != nil }
            return dated + SubsetRule.random.choose(from: undated, count: count - datedCount, seed: seed)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var months: [Int: [PhotoDescriptor]] = [:]
        for photo in photos {
            guard let date = photo.creationDate else { continue }
            let parts = calendar.dateComponents([.year, .month], from: date)
            months[parts.year! * 12 + parts.month!, default: []].append(photo)
        }
        let keys = months.keys.sorted()
        let sizes = keys.map { months[$0]!.count }

        // The smallest level that reaches `count`; then one below it
        // everywhere, and the remainder handed out one each to the months that
        // have that many, in an order fixed by the seed.
        //
        // Not spread by position among those months, as it first was: taking
        // photographs out of the library changes which months qualify, and a
        // positional spread then moved the extra one from a month to another,
        // pushing out a photograph that had been chosen. Filling the subset
        // to its target rests on that never happening (`monotone` in the
        // tests); a fixed order keeps a month that had the extra one ahead of
        // every month that did not.
        var level = 0
        while sizes.reduce(0, { $0 + min($1, level) }) < count { level += 1 }
        var shares = sizes.map { min($0, level - 1) }
        let eligible = sizes.indices.filter { sizes[$0] >= level }
            .map { (rank: Self.rank(ofMonth: keys[$0], seed: seed), month: $0) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.month < $1.month }
            .map(\.month)
        let remainder = count - shares.reduce(0, +)
        for month in eligible.prefix(remainder) {
            shares[month] += 1
        }

        var chosen: [PhotoDescriptor] = []
        chosen.reserveCapacity(count)
        for (index, key) in keys.enumerated() where shares[index] > 0 {
            chosen += SubsetRule.random.choose(from: months[key]!, count: shares[index], seed: seed)
        }
        return chosen
    }
}

/// A source that stands for `target` photographs chosen from a larger whole,
/// and can choose again leaving some out (SPEC § 5).
///
/// What an index is filled to its target with: a photograph that cannot be
/// read here — kept only in iCloud, or broken — is left out and the choice is
/// made again, so another takes its place instead of the subset thinning out.
/// Leaving photographs out must never push out one that was chosen and stays
/// (`SubsetRule`'s `monotone` test), or every round would undo the last.
///
/// The whole is read once (`library`) and chosen from as often as it takes
/// (`choose`): a round of filling must not fetch 54,000 photographs again.
public protocol FillablePhotoSource: PhotoSource {
    var target: Int { get }
    /// Everything the subset is chosen from.
    func library() throws -> [PhotoDescriptor]
    /// `count` of `library` by the source's rule, leaving out the identifiers
    /// in `excluded`. Indexing asks for the target, and first for the share of
    /// it that has to fill the screen.
    func choose(from library: [PhotoDescriptor], excluding excluded: Set<String>, count: Int) -> [PhotoDescriptor]
    /// What the choice depends on besides the library: another value, another
    /// choice.
    var choice: String { get }
}

/// A source narrowed to the subset a rule picks. Everything but the list of
/// photographs passes straight through.
public struct SubsetPhotoSource<Base: PhotoSource>: FillablePhotoSource {
    public let base: Base
    public let rule: SubsetRule
    public let count: Int
    public let seed: UInt64

    public init(_ base: Base, rule: SubsetRule, count: Int, seed: UInt64) {
        self.base = base
        self.rule = rule
        self.count = count
        self.seed = seed
    }

    public var target: Int { count }

    public var choice: String { "\(rule.rawValue) \(count) \(seed)" }

    public func photos() throws -> [PhotoDescriptor] {
        choose(from: try library(), excluding: [], count: count)
    }

    public func library() throws -> [PhotoDescriptor] {
        try base.photos()
    }

    public func choose(from library: [PhotoDescriptor], excluding excluded: Set<String>, count: Int) -> [PhotoDescriptor] {
        let candidates = excluded.isEmpty ? library : library.filter { !excluded.contains($0.id.rawValue) }
        return rule.choose(from: candidates, count: count, seed: seed)
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        try base.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }

    public func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage {
        try base.uprightImage(for: id, cropWidth: cropWidth)
    }
}
