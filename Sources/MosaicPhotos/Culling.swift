import Foundation
import MosaicCore

/// What a source knows of a photograph's looks before reading it: Photos'
/// aesthetic score, 0 to 1 and higher is better, or none; and whether it is a
/// screenshot (spike 5).
public struct PhotoQuality: Equatable, Sendable {
    /// Nil when Photos has not analysed the photograph, or this Mac cannot
    /// tell. 0 is a score, the bottom of the scale.
    public var score: Double?
    public var isScreenshot: Bool

    public init(score: Double? = nil, isScreenshot: Bool = false) {
        self.score = score
        self.isScreenshot = isScreenshot
    }
}

/// Where `PhotoQuality` comes from: the Photos library's database, in the app.
///
/// Never an error. A source that cannot read what it reads from — no
/// permission, no database, a schema it does not know — answers with nothing,
/// and the photographs are then judged by Vision as they are indexed.
public protocol PhotoQualitySource: Sendable {
    /// For the photographs of `photos` the source knows anything about.
    func qualities(of photos: [PhotoDescriptor]) -> [PhotoID: PhotoQuality]
}

/// A source that knows nothing.
public struct NoPhotoQuality: PhotoQualitySource {
    public init() {}

    public func qualities(of photos: [PhotoDescriptor]) -> [PhotoID: PhotoQuality] { [:] }
}

/// The photographs left out of a library before its subset is chosen, and the
/// bar the others are judged by once Vision has seen them (evolution 4).
///
/// Screenshots go, then the worst `share` of the photographs that have a
/// score: month by month for `uniformInTime`, so that a month of dim photographs
/// keeps its share of the subset, and over the whole library otherwise. A
/// photograph without a score is neither left out nor favoured here; Vision
/// judges it against the bar of its month when it is indexed.
///
/// The bar is a value, not a rank: what is below the `share` quantile goes, so a
/// score from Vision, mapped onto Photos' scale, is judged as one from Photos is.
/// A month with fewer than `minimumScored` scores has too few to set a bar of
/// its own and takes the library's; a library with fewer takes `referenceBar`.
public struct Culling: Sendable {
    /// Decided by Sergio on 2026-10-17.
    public static let standardShare = 0.10

    /// Below this a month's bar is noise: with 20 scores, its worst 10 % is 2.
    public static let minimumScored = 20

    /// The bar when this Mac has no scores: the 10 % quantile of Photos'
    /// scores over Sergio's library, 54,028 photographs without screenshots or
    /// placeholders (spike 5, `sergio-assets.csv`). The library Vision's map
    /// onto Photos' scale was fitted on.
    public static let referenceBar = 0.307373046875

    /// The library less what is left out, in the order it came.
    public let kept: [PhotoDescriptor]
    public let screenshots: Int
    /// Left out for their score.
    public let weak: Int
    /// Of the library, those with a score.
    public let scored: Int

    private let scores: [PhotoID: Double]
    private let monthBars: [Int: Double]
    /// The library's bar.
    public let libraryBar: Double
    private let byMonth: Bool

    public init(
        library: [PhotoDescriptor], qualities: [PhotoID: PhotoQuality], rule: SubsetRule,
        share: Double = Culling.standardShare
    ) {
        let candidates = library.filter { qualities[$0.id]?.isScreenshot != true }
        var scores: [PhotoID: Double] = [:]
        for photo in candidates {
            if let score = qualities[photo.id]?.score { scores[photo.id] = score }
        }
        let libraryBar = Self.bar(of: Array(scores.values), share: share) ?? Self.referenceBar

        var monthBars: [Int: Double] = [:]
        let byMonth = rule == .uniformInTime
        if byMonth {
            var months: [Int: [Double]] = [:]
            for photo in candidates {
                guard let score = scores[photo.id], let date = photo.creationDate else { continue }
                months[SubsetRule.month(of: date), default: []].append(score)
            }
            for (month, values) in months {
                if let bar = Self.bar(of: values, share: share) { monthBars[month] = bar }
            }
        }

        self.scores = scores
        self.monthBars = monthBars
        self.libraryBar = libraryBar
        self.byMonth = byMonth
        self.screenshots = library.count - candidates.count
        self.scored = scores.count

        var weak = 0
        var kept: [PhotoDescriptor] = []
        kept.reserveCapacity(candidates.count)
        for photo in candidates {
            if let score = scores[photo.id], score < Self.bar(for: photo, months: monthBars, library: libraryBar, byMonth: byMonth) {
                weak += 1
            } else {
                kept.append(photo)
            }
        }
        self.kept = kept
        self.weak = weak
    }

    /// Whether Photos scored this photograph, so Vision need not.
    public func hasScore(_ id: PhotoID) -> Bool {
        scores[id] != nil
    }

    /// What a score on Photos' scale must reach for `photo` to stay.
    public func bar(for photo: PhotoDescriptor) -> Double {
        Self.bar(for: photo, months: monthBars, library: libraryBar, byMonth: byMonth)
    }

    private static func bar(for photo: PhotoDescriptor, months: [Int: Double], library: Double, byMonth: Bool) -> Double {
        guard byMonth, let date = photo.creationDate else { return library }
        return months[SubsetRule.month(of: date)] ?? library
    }

    /// The `share` quantile of `values`: of `n` distinct values, the
    /// `round(n · share)` below it go. Nil with fewer than `minimumScored`.
    static func bar(of values: [Double], share: Double) -> Double? {
        guard values.count >= minimumScored else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * share).rounded()))
        return sorted[index]
    }
}
