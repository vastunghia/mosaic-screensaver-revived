import PhotoIndex

extension IndexProgress {
    /// One line under the progress bar.
    var summary: String {
        var parts = ["\(completed) of \(total)"]
        if reused > 0 { parts.append("\(reused) already indexed") }
        if ready > fullScreen { parts.append("\(ready - fullScreen) only as tiles") }
        if skipped > 0 { parts.append("\(skipped) unreadable") }
        if unavailable > 0 { parts.append("\(unavailable) only in iCloud") }
        if skipped + unavailable > 0 { parts[parts.count - 1] += ", left out" }
        if rejected > 0 { parts.append("\(rejected) left out as documents or weak") }
        return parts.joined(separator: " · ")
    }
}
