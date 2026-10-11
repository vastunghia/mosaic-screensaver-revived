import PhotoIndex

extension IndexProgress {
    /// One line under the progress bar.
    var summary: String {
        var parts = ["\(completed) of \(total)"]
        if reused > 0 { parts.append("\(reused) already indexed") }
        if skipped > 0 { parts.append("\(skipped) unreadable") }
        if unavailable > 0 { parts.append("\(unavailable) only in iCloud") }
        if skipped + unavailable > 0 { parts[parts.count - 1] += ", left out" }
        return parts.joined(separator: " · ")
    }
}
