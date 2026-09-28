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
    /// Evenly spread over the time the library covers — a photograph near each
    /// of `N` equally spaced moments. Less stable than the other two: a new
    /// photograph that extends the span moves every moment a little.
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

    /// For each of `count` equally spaced moments, the nearest photograph not
    /// already taken. Where the library has a gap — a year without photographs
    /// — the moments inside it fall to the photographs at its edges, so a gap
    /// thickens its borders rather than going unrepresented. Undated
    /// photographs are drawn on only if the dated ones run out, by `random`.
    static func spreadOverTime(_ photos: [PhotoDescriptor], count: Int, seed: UInt64) -> [PhotoDescriptor] {
        let dated = photos
            .filter { $0.creationDate != nil }
            .sorted { a, b in
                a.creationDate! != b.creationDate! ? a.creationDate! < b.creationDate! : byIdentifier(a, b)
            }
        let undated = photos.filter { $0.creationDate == nil }

        guard dated.count > count else {
            let rest = SubsetRule.random.choose(from: undated, count: count - dated.count, seed: seed)
            return dated + rest
        }

        let times = dated.map { $0.creationDate!.timeIntervalSinceReferenceDate }
        let first = times.first!, last = times.last!
        let step = (last - first) / Double(count)
        var taken = [Bool](repeating: false, count: dated.count)
        var chosen: [PhotoDescriptor] = []
        chosen.reserveCapacity(count)

        for moment in 0..<count {
            let target = first + (Double(moment) + 0.5) * step
            // The first photograph at or after the target…
            var low = 0, high = times.count
            while low < high {
                let middle = (low + high) / 2
                if times[middle] < target { low = middle + 1 } else { high = middle }
            }
            // …then outwards to the nearest one still free. Ties go earlier.
            // There is always one: fewer moments than photographs.
            var before = low - 1, after = low
            while before >= 0, taken[before] { before -= 1 }
            while after < times.count, taken[after] { after += 1 }
            let pick: Int
            if before < 0 {
                pick = after
            } else if after >= times.count {
                pick = before
            } else {
                pick = target - times[before] <= times[after] - target ? before : after
            }
            taken[pick] = true
            chosen.append(dated[pick])
        }
        return chosen
    }
}

/// A source narrowed to the subset a rule picks. Everything but the list of
/// photographs passes straight through.
public struct SubsetPhotoSource<Base: PhotoSource>: PhotoSource {
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

    public func photos() throws -> [PhotoDescriptor] {
        rule.choose(from: try base.photos(), count: count, seed: seed)
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        try base.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }
}
