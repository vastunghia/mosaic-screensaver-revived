import Foundation

/// How often the subset is chosen again with a new seed (evolution 2, SPEC § 5).
///
/// The seed of `SubsetRule` stays the same for as long as it is kept, so the
/// same 2048 photographs come round for ever, and the same subjects with them.
/// A renewal draws another seed: subjects, tiles and close-ups all change on
/// the same day, since changing the close-ups is what it is for. With
/// `SubsetRule.recent` the seed decides nothing, and nothing changes.
public enum SubsetRenewal: String, CaseIterable, Sendable {
    case never
    case daily
    case weekly
    case monthly

    /// Chosen by Sergio on 2026-10-19: often enough to notice, and a renewal's
    /// downloads, about 270 on an optimised library, fit within a week's cap.
    public static let standard = SubsetRenewal.weekly

    /// When a subset chosen at `renewed` is due to be chosen again, by the
    /// calendar: a month is a month, from the 31st to the last day of the
    /// next. Nil for `never`.
    public func due(after renewed: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .never: nil
        case .daily: calendar.date(byAdding: .day, value: 1, to: renewed)
        case .weekly: calendar.date(byAdding: .day, value: 7, to: renewed)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: renewed)
        }
    }

    public func isDue(renewed: Date, now: Date, calendar: Calendar = .current) -> Bool {
        due(after: renewed, calendar: calendar).map { $0 <= now } ?? false
    }
}
