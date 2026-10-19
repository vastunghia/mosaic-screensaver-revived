import Foundation
import PhotoIndex

/// Sharp close-ups still to download after a run, and why: the window says
/// so, rather than show the photographs ready and nothing else (Sergio,
/// 2026-10-13: downloads cost the user's disk and network, no surprises).
struct CloseUpsWaiting: Equatable {
    enum Reason: Equatable {
        /// iCloud stopped answering; the run is tried again at `retry`, if
        /// one is planned.
        case stalled(retry: Date?)
        /// The ledger's caps for the day or the week.
        case limits
        /// A hotspot, or Low Data Mode: nothing was asked for.
        case metered
        /// Given up on as too slow, or resting after too many runs.
        case slow
    }

    var count: Int
    /// Tiles picked for the anchor's ring, still to download after them.
    var ring = 0
    var reason: Reason?

    /// From a run's report, when sharp close-ups may be downloaded; nil
    /// when none is missing.
    init?(_ report: CloseUpShelf.StockReport, metered: Bool) {
        guard report.unavailable + report.ringWaiting > 0 else { return nil }
        count = report.unavailable
        ring = report.ringWaiting
        reason = if metered {
            .metered
        } else if report.stalled {
            .stalled(retry: nil)
        } else if report.deferred + report.ringDeferred > 0 {
            .limits
        } else if report.timedOut + report.resting > 0 {
            .slow
        } else {
            nil
        }
    }

    var summary: String {
        let closeUps = String(localized: "\(count) sharp close-ups",
                              comment: "Close-ups still to download from iCloud; begins a sentence")
        let tiles = String(localized: "\(ring) sharper tiles",
                           comment: "Sharper copies of tiles still to download from iCloud; begins a sentence")
        let missing = switch (count > 0, ring > 0) {
        case (true, true): String(localized: "\(closeUps) and \(tiles)",
                                  comment: "Close-ups and tiles still to download, as in “3 sharp close-ups and 5 sharper tiles”")
        case (false, true): tiles
        default: closeUps
        }
        return switch reason {
        case .stalled(let retry?):
            String(localized: "\(missing) still to download: iCloud stopped answering. Mosaic Companion tries again at \(retry.formatted(date: .omitted, time: .shortened)).",
                   comment: "What is still to download, then why and when it is tried again")
        case .stalled(nil):
            String(localized: "\(missing) still to download: iCloud stopped answering. Mosaic Companion tries again later.",
                   comment: "What is still to download, then why")
        case .limits:
            String(localized: "\(missing) still to download: the limit of \(DownloadLedger.standardDailyLimit) a day or \(DownloadLedger.standardWeeklyLimit) a week is reached. Mosaic Companion goes on as soon as it allows.",
                   comment: "What is still to download, then the daily and weekly download limits that hold it back")
        case .metered:
            String(localized: "\(missing) still to download: the network is metered (a hotspot, or Low Data Mode).",
                   comment: "What is still to download, then why")
        case .slow:
            String(localized: "\(missing) still to download: iCloud was too slow to send them. Mosaic Companion asks again later.",
                   comment: "What is still to download, then why")
        case nil:
            String(localized: "\(missing) still to download: Mosaic Companion tries again later.",
                   comment: "What is still to download, with no particular reason")
        }
    }
}
