import PhotoIndex

extension IndexProgress {
    /// One line under the progress bar: a fragment per figure, each whole in
    /// every language, joined by a middle dot.
    var summary: String {
        var parts = [String(localized: "\(completed) of \(total)",
                            comment: "Index progress: photographs prepared so far, of all those to prepare")]
        if reused > 0 {
            parts.append(String(localized: "\(reused) already indexed",
                                comment: "Index progress: photographs prepared in an earlier run"))
        }
        if ready > fullScreen {
            parts.append(String(localized: "\(ready - fullScreen) only as tiles",
                                comment: "Index progress: photographs too small to fill the screen, used only as tiles"))
        }
        // "left out" closes the last of the two figures it applies to.
        if skipped > 0 {
            parts.append(unavailable > 0
                ? String(localized: "\(skipped) unreadable",
                         comment: "Index progress: photographs that could not be read; followed by the iCloud figure")
                : String(localized: "\(skipped) unreadable, left out",
                         comment: "Index progress: photographs that could not be read and are not used"))
        }
        if unavailable > 0 {
            parts.append(String(localized: "\(unavailable) only in iCloud, left out",
                                comment: "Index progress: photographs whose originals are only in iCloud and are not used"))
        }
        if rejected > 0 {
            parts.append(String(localized: "\(rejected) left out as documents or weak",
                                comment: "Index progress: screenshots, documents and the lowest-rated photographs, not used"))
        }
        return parts.joined(separator: " · ")
    }
}
