import CoreGraphics
import Foundation
import ImageIO
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex
import UniformTypeIdentifiers

/// `--export-culling DIR`: what leaving weak photographs out takes from the
/// library, month by month, for judging the bar by eye (evolution 4).
///
/// Photos' scores are read as a build reads them, and Vision's verdicts are
/// those the index at `--index` remembers: run it after a build with
/// `--cull on`. Writes `index.html`, month by month: the worst photographs
/// Photos' score leaves out, the last ones below the bar and the first above
/// it, and those Vision left out; `utility.html`, every photograph Vision
/// called a utility shot, by the image that said so; `summary.csv` and
/// `rejected.csv`. Previews are what this Mac has at 256 px, never fetched:
/// a photograph with nothing here is a grey square.
///
/// A function of the library and the index: the same on two runs, until
/// Photos analyses more photographs.
enum CullingSpecimen {
    static let previewSide = 256
    /// Of each month: the worst, the last below the bar, the first above it.
    static let shown = 4

    struct Month {
        var key: Int
        var photos: [PhotoDescriptor] = []
        var scored = 0
        var screenshots = 0
        var weak: [PhotoDescriptor] = []
        var bar = 0.0
        /// Kept, with a score, the lowest first.
        var aboveBar: [PhotoDescriptor] = []
        var judged = 0
        var visionWeak: [PhotoDescriptor] = []
        var utility: [PhotoDescriptor] = []
    }

    static func export(_ indexable: any PhotoSource, rule: SubsetRule, manifest: IndexManifest?, to directory: URL) throws {
        guard let source = indexable as? SubsetPhotoSource<PhotoKitPhotoSource> else {
            print("export-culling: only the Photos library is culled")
            return
        }
        let previews = directory.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        let whole = try source.library()
        let qualities = PhotosDatabaseQualitySource().qualities(of: whole)
        let culling = Culling(library: whole, qualities: qualities, rule: rule)
        let kept = Set(culling.kept.map(\.id))
        let assessments = Dictionary((manifest?.assessments ?? []).map { ($0.id, $0) }) { _, last in last }
        print("culling: \(whole.count) photographs, \(culling.scored) scored by Photos, "
              + "\(culling.screenshots) screenshots, \(culling.weak) below the bar; "
              + "\(assessments.count) judged by Vision in the index")

        var months: [Int: Month] = [:]
        func score(_ photo: PhotoDescriptor) -> Double { qualities[photo.id]?.score ?? 0 }
        for photo in whole {
            let key = photo.creationDate.map(monthKey) ?? 0
            var month = months[key] ?? Month(key: key)
            month.photos.append(photo)
            let quality = qualities[photo.id]
            if quality?.isScreenshot == true {
                month.screenshots += 1
            } else if quality?.score != nil {
                month.scored += 1
                if kept.contains(photo.id) { month.aboveBar.append(photo) } else { month.weak.append(photo) }
            }
            month.bar = culling.bar(for: photo)
            if kept.contains(photo.id), let assessment = assessments[photo.id.rawValue],
               assessment.versionToken == photo.versionToken {
                month.judged += 1
                if assessment.utility || assessment.smallUtility == true {
                    month.utility.append(photo)
                } else if assessment.rejects(photo, by: culling) {
                    month.visionWeak.append(photo)
                }
            }
            months[key] = month
        }
        for key in months.keys {
            months[key]!.weak.sort { (score($0), $0.id.rawValue) < (score($1), $1.id.rawValue) }
            months[key]!.aboveBar.sort { (score($0), $0.id.rawValue) < (score($1), $1.id.rawValue) }
        }
        let ordered = months.values.sorted { $0.key < $1.key }

        // The previews every page shows, fetched once, on every core.
        var wanted: Set<PhotoID> = []
        for month in ordered {
            wanted.formUnion(month.weak.prefix(shown).map(\.id))
            wanted.formUnion(month.weak.suffix(shown).map(\.id))
            wanted.formUnion(month.aboveBar.prefix(shown).map(\.id))
            wanted.formUnion(month.visionWeak.map(\.id))
            wanted.formUnion(month.utility.map(\.id))
        }
        let list = wanted.sorted { $0.rawValue < $1.rawValue }
        let missing = Missing()
        DispatchQueue.concurrentPerform(iterations: list.count) { offset in
            let id = list[offset]
            let url = previews.appendingPathComponent(name(of: id) + ".jpg")
            if FileManager.default.fileExists(atPath: url.path) { return }
            guard let image = source.base.wholeImage(for: id, longSide: previewSide), (try? jpeg(image, to: url)) != nil else {
                missing.add(id)
                return
            }
        }
        print("  \(list.count) previews, \(missing.count) not on this Mac")

        func tile(_ photo: PhotoDescriptor, _ note: String) -> String {
            let file = "previews/\(name(of: photo.id)).jpg"
            let image = missing.contains(photo.id)
                ? "<div class=\"none\">\(escape(name(of: photo.id)))</div>"
                : "<a href=\"\(file)\"><img src=\"\(file)\" loading=\"lazy\" alt=\"\"></a>"
            return "<figure>\(image)<figcaption>\(note)</figcaption></figure>"
        }
        func scoreNote(_ photo: PhotoDescriptor) -> String { String(format: "%.3f", score(photo)) }
        func visionNote(_ photo: PhotoDescriptor) -> String {
            guard let raw = assessments[photo.id.rawValue]?.score else { return "Vision –" }
            return String(format: "Vision %.2f → %.3f", raw, VisionScoreMap.photosScore(forVision: Double(raw)))
        }
        func utilityNote(_ photo: PhotoDescriptor) -> String {
            guard let assessment = assessments[photo.id.rawValue] else { return "" }
            switch (assessment.utility, assessment.smallUtility) {
            case (true, true?): return "854 and 427"
            case (true, false?): return "854 only"
            // Photos had a score: Vision was not asked at 427.
            case (true, nil): return "854, 427 not asked"
            default: return "427 only"
            }
        }

        var body = ""
        for month in ordered {
            let title = month.key == 0 ? "Undated" : String(format: "%04d-%02d", (month.key - 1) / 12, (month.key - 1) % 12 + 1)
            let gone = month.weak.count + month.screenshots + month.visionWeak.count + month.utility.count
            body += """
            <h2 id="m\(month.key)">\(title) <span>\(month.photos.count) photographs · \(month.scored) scored · bar \(String(format: "%.3f", month.bar)) · \
            \(month.weak.count) below it · \(month.screenshots) screenshots · Vision: \(month.judged) judged, \(month.visionWeak.count) below the bar, \
            \(month.utility.count) utility · \(gone) left out in all</span></h2>\n
            """
            var rows: [(String, [String])] = []
            if !month.weak.isEmpty {
                rows.append(("worst", month.weak.prefix(shown).map { tile($0, scoreNote($0)) }))
                if month.weak.count > shown {
                    rows.append(("last below the bar", month.weak.suffix(min(shown, month.weak.count - shown)).map { tile($0, scoreNote($0)) }))
                }
            }
            if !month.aboveBar.isEmpty, !month.weak.isEmpty {
                rows.append(("first above it, kept", month.aboveBar.prefix(shown).map { tile($0, scoreNote($0)) }))
            }
            if !month.visionWeak.isEmpty {
                rows.append(("Vision, below the bar", month.visionWeak.map { tile($0, visionNote($0)) }))
            }
            if !month.utility.isEmpty {
                rows.append(("Vision, utility", month.utility.map { tile($0, utilityNote($0)) }))
            }
            for (label, tiles) in rows {
                body += "<div class=\"row\"><div class=\"label\">\(label)</div>\(tiles.joined())</div>\n"
            }
        }

        let utility = ordered.flatMap(\.utility)
        var utilityBody = ""
        for kind in ["854 and 427", "854 only", "427 only", "854, 427 not asked"] {
            let photos = utility.filter { utilityNote($0) == kind }
            utilityBody += "<h2>\(kind) <span>\(photos.count)</span></h2>\n<div class=\"grid\">\(photos.map { tile($0, String($0.id.rawValue.prefix(8))) }.joined())</div>\n"
        }

        let totals = """
        \(whole.count) photographs · \(culling.scored) scored by Photos · \(culling.screenshots) screenshots · \
        \(culling.weak) below the bar of their \(rule == .uniformInTime ? "month" : "library") (library bar \(String(format: "%.3f", culling.libraryBar))) · \
        Vision: \(ordered.map(\.judged).reduce(0, +)) judged, \(ordered.map(\.visionWeak.count).reduce(0, +)) below the bar, \(utility.count) utility
        """
        try page(title: "Culling, month by month", note: totals + " · <a href=\"utility.html\">utility shots</a>", body: body)
            .write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try page(title: "Utility shots", note: "\(utility.count) photographs Vision called a utility shot, by the image that said so · <a href=\"index.html\">month by month</a>", body: utilityBody)
            .write(to: directory.appendingPathComponent("utility.html"), atomically: true, encoding: .utf8)

        var summary = ["month,photographs,scored,bar,below_bar,screenshots,vision_judged,vision_below_bar,utility"]
        var rejected = ["id,month,reason,photos_score,bar,vision_score,vision_mapped"]
        for month in ordered {
            summary.append([
                "\(month.key)", "\(month.photos.count)", "\(month.scored)", String(format: "%.4f", month.bar),
                "\(month.weak.count)", "\(month.screenshots)", "\(month.judged)", "\(month.visionWeak.count)", "\(month.utility.count)",
            ].joined(separator: ","))
            func row(_ photo: PhotoDescriptor, _ reason: String) {
                let raw = assessments[photo.id.rawValue]?.score
                rejected.append([
                    photo.id.rawValue, "\(month.key)", reason,
                    qualities[photo.id]?.score.map { String(format: "%.4f", $0) } ?? "",
                    String(format: "%.4f", month.bar), raw.map { String(format: "%.4f", $0) } ?? "",
                    raw.map { String(format: "%.4f", VisionScoreMap.photosScore(forVision: Double($0))) } ?? "",
                ].joined(separator: ","))
            }
            for photo in month.weak { row(photo, "photos-score") }
            for photo in month.photos where qualities[photo.id]?.isScreenshot == true { row(photo, "screenshot") }
            for photo in month.visionWeak { row(photo, "vision-score") }
            for photo in month.utility { row(photo, "utility-" + utilityNote(photo).replacingOccurrences(of: " ", with: "-")) }
        }
        try (summary.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
        try (rejected.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("rejected.csv"), atomically: true, encoding: .utf8)
        print("  \(directory.appendingPathComponent("index.html").path)")
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// As `SubsetRule` counts months, so that the bars here are the build's.
    private static func monthKey(_ date: Date) -> Int {
        let parts = utc.dateComponents([.year, .month], from: date)
        return parts.year! * 12 + parts.month!
    }

    private static func name(of id: PhotoID) -> String {
        String(id.rawValue.prefix { $0 != "/" })
    }

    private static func jpeg(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.couldNotWrite(url) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotWrite(url) }
    }

    private static func page(title: String, note: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { --bg: #fafaf8; --ink: #1d1d1b; --muted: #6b6b66; --rule: #c9c8c2; --none: #d8d7d2; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1a; --ink: #ecebe6; --muted: #9a9993; --rule: #4a4a45; --none: #3a3a37; } }
        body { background: var(--bg); color: var(--ink); font: 14px/1.4 -apple-system, system-ui, sans-serif; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 32px 0 6px; border-top: 1px solid var(--rule); padding-top: 12px; }
        h2 span, .muted, .label { color: var(--muted); font-weight: normal; }
        h2 span { font-size: 12px; font-variant-numeric: tabular-nums; }
        .row, .grid { display: flex; flex-wrap: wrap; gap: 8px; align-items: flex-start; margin: 6px 0; }
        .label { width: 140px; font-size: 12px; padding-top: 4px; }
        figure { margin: 0; width: 160px; }
        figure img { width: 160px; height: 120px; object-fit: contain; background: var(--none); display: block; }
        .none { width: 160px; height: 120px; background: var(--none); color: var(--muted); font-size: 10px; display: flex; align-items: center; justify-content: center; }
        figcaption { font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; margin-top: 2px; }
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        <p class="muted">\(note)</p>
        \(body)
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class Missing: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<PhotoID> = []

    func add(_ id: PhotoID) { lock.lock(); ids.insert(id); lock.unlock() }
    func contains(_ id: PhotoID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
}
