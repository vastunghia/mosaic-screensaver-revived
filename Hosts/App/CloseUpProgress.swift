import PhotoIndex

/// How far the close-ups have got after a build: first those made from what
/// this Mac has, then those downloaded from iCloud. Without a row of its own
/// the window kept the index's full bar for minutes, while 2,014 originals
/// were decoded again (2026-10-19).
enum CloseUpProgress: Equatable {
    case making(tried: Int, of: Int)
    case downloading(asked: Int, of: Int)

    /// From a run's report, nil while there is nothing to make or download.
    init?(_ report: CloseUpShelf.StockReport) {
        if report.toFetch > 0 {
            self = .downloading(asked: report.asked, of: report.toFetch)
        } else if report.toMake > 0 {
            self = .making(tried: report.tried, of: report.toMake)
        } else {
            return nil
        }
    }
}
