import CoreGraphics
import Foundation
import ImageIO
import MosaicCore
import MosaicPhotos
import PhotoIndex
import UniformTypeIdentifiers

/// `--export-faces DIR`: where the face-aware crop (SPEC § 4) would put the
/// window of every photograph in a folder, what finding the faces costs, and a
/// page to judge it by.
///
/// Measured before the crop becomes part of the index, because two numbers
/// decide whether it is worth it: how long Vision takes per photograph on top
/// of the decode indexing already pays, and on how many photographs the window
/// actually moves.
///
/// Writes `faces.csv` (one row per photograph), `index.html` with the
/// photographs whose window moved — whole photograph with faces and both
/// windows, centre crop, face-aware crop — and `timing.txt`. Everything but
/// `timing.txt` is a pure function of the folder, the widths and the Vision
/// revision.
enum FaceSpecimen {
    /// One photograph's result. Coordinates are in the pixels of the image
    /// searched at the first width.
    struct Row: Sendable {
        let id: String
        let width: Int
        let height: Int
        let faces: [FaceDetector.Face]
        /// Faces found at each width, in the same order as the widths.
        let counts: [Int]
        /// Faces found at the other widths, mapped into the first width's pixels.
        let otherFaces: [CGRect]
        let choice: FaceAwareCrop.Choice
        let decodeTime: Double
        let visionTimes: [Double]
        var file: String?
    }

    @inline(never)
    static func export(from source: FolderPhotoSource, to directory: URL, widths: [Int]) throws {
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        let photos = try source.photos()
        guard let primary = widths.first else { preconditionFailure("--export-faces: no widths") }
        print("faces: \(photos.count) photographs in \(source.root.lastPathComponent), "
              + "Vision revision \(FaceDetector.revision), at \(widths.map(String.init).joined(separator: ", ")) px")

        let collected = Collected()
        let started = Date()
        DispatchQueue.concurrentPerform(iterations: photos.count) { offset in
            let id = photos[offset].id
            do {
                guard let url = source.url(for: id) else { throw PhotoSourceError.unknownPhoto(id) }
                collected.add(try measure(
                    id, at: url, widths: widths, name: String(format: "p%04d", offset), images: images
                ))
            } catch {
                collected.fail(id.rawValue, error)
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let rows = collected.rows.sorted { $0.id < $1.id }

        try csv(rows, widths: widths).write(
            to: directory.appendingPathComponent("faces.csv"), atomically: true, encoding: .utf8
        )
        let summary = summarise(rows, widths: widths)
        try page(rows, summary: summary, widths: widths, folder: source.root.lastPathComponent).write(
            to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        let timing = timingReport(rows, widths: widths, elapsed: elapsed, failures: collected.failures)
        try timing.write(to: directory.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)

        print(summary.map { "  \($0.0): \($0.1)" }.joined(separator: "\n"))
        print(timing)
        print("faces: written to \(directory.path) (primary width \(primary) px)")
    }

    /// One photograph: decoded once at the largest width, searched at each,
    /// its window chosen at the first, and its images written if it has a row.
    private static func measure(
        _ id: PhotoID, at url: URL, widths: [Int], name: String, images: URL
    ) throws -> Row {
        guard let largest = widths.max() else { preconditionFailure("no widths to search at") }
        let decodeStart = Date()
        let decoded = try CanonicalCrop.uprightImage(at: url, cropWidth: largest)
        let decodeTime = Date().timeIntervalSince(decodeStart)

        var searched: [(image: CGImage, faces: [FaceDetector.Face], time: Double)] = []
        for width in widths {
            let image = try scaled(decoded, cropWidth: width)
            let visionStart = Date()
            let faces = try FaceDetector.faces(in: image)
            searched.append((image, faces, Date().timeIntervalSince(visionStart)))
        }

        let first = searched[0]
        let choice = FaceAwareCrop.choose(
            width: first.image.width, height: first.image.height, faces: first.faces.map(\.rect)
        )
        let others = searched.dropFirst().flatMap { other in
            let ratio = Double(first.image.width) / Double(other.image.width)
            return other.faces.map { face in
                CGRect(x: face.rect.minX * ratio, y: face.rect.minY * ratio,
                       width: face.rect.width * ratio, height: face.rect.height * ratio)
            }
        }
        var row = Row(
            id: id.rawValue, width: first.image.width, height: first.image.height,
            faces: first.faces, counts: searched.map(\.faces.count), otherFaces: others,
            choice: choice, decodeTime: decodeTime, visionTimes: searched.map(\.time)
        )
        if shows(row) {
            try write(row, image: first.image, named: name, in: images)
            row.file = name
        }
        return row
    }

    /// The decoded image brought down to the size whose canonical crop is
    /// `cropWidth` across — never up.
    private static func scaled(_ image: CGImage, cropWidth: Int) throws -> CGImage {
        let crop = CanonicalCrop.rect(width: image.width, height: image.height)
        let factor = Double(cropWidth) / Double(crop.width)
        guard factor < 1 else { return image }
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ExportError.couldNotMakeImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.couldNotMakeImage }
        return result
    }

    /// Whether a photograph earns a row on the page: its window moved, a face
    /// is cut wherever the window goes, or the widths disagree on its faces.
    private static func shows(_ row: Row) -> Bool {
        row.choice.shift != 0 || row.choice.cut > 0 || Set(row.counts).count > 1
    }

    // MARK: - Images

    private static func write(_ row: Row, image: CGImage, named name: String, in directory: URL) throws {
        try jpeg(overlay(row, image: image), to: directory.appendingPathComponent("\(name)-whole.jpg"))
        let centre = CanonicalCrop.rect(width: image.width, height: image.height)
        try jpeg(CanonicalCrop.image(image, cropping: centre, maxPixelWidth: 640),
                 to: directory.appendingPathComponent("\(name)-centre.jpg"))
        try jpeg(CanonicalCrop.image(image, cropping: row.choice.rect, maxPixelWidth: 640),
                 to: directory.appendingPathComponent("\(name)-faces.jpg"))
    }

    /// The whole photograph, at most 480 px tall, with the faces in yellow and
    /// the head counted above each dashed, faces the frame already cuts in grey,
    /// faces only another width found in cyan, the centre window dashed and
    /// the chosen one in green.
    private static func overlay(_ row: Row, image: CGImage) throws -> CGImage {
        let scale = min(480 / Double(image.height), 854 / Double(image.width), 1)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ExportError.couldNotMakeImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Rectangles are top-left; the context draws bottom-left.
        func draw(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, line: CGFloat, dash: [CGFloat] = []) {
            let flipped = CGRect(
                x: rect.minX * scale, y: Double(height) - rect.maxY * scale,
                width: rect.width * scale, height: rect.height * scale
            ).insetBy(dx: line / 2, dy: line / 2)
            context.setStrokeColor(red: r, green: g, blue: b, alpha: 1)
            context.setLineWidth(line)
            context.setLineDash(phase: 0, lengths: dash)
            context.stroke(flipped)
        }

        let centre = CanonicalCrop.rect(width: image.width, height: image.height)
        draw(centre, 1, 0.25, 0.25, line: 2, dash: [8, 6])
        draw(row.choice.rect, 0.2, 0.9, 0.3, line: 3)
        for face in row.otherFaces { draw(face, 0.2, 0.85, 1, line: 1.5) }
        for face in row.faces {
            if FaceAwareCrop.isCutByFrame(face.rect, width: image.width, height: image.height) {
                draw(face.rect, 0.6, 0.6, 0.6, line: 2)
                continue
            }
            draw(FaceAwareCrop.head(of: face.rect), 1, 0.85, 0.1, line: 1, dash: [4, 4])
            draw(face.rect, 1, 0.85, 0.1, line: 2)
        }

        guard let result = context.makeImage() else { throw ExportError.couldNotMakeImage }
        return result
    }

    private static func jpeg(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ExportError.couldNotWrite(url) }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotWrite(url) }
    }

    // MARK: - Numbers

    private static func shape(_ row: Row) -> String {
        // A pixel of room is rounding, not a shape: 4032x2268 is 16:9.
        if row.choice.slack <= 1 { return "16:9" }
        if row.height > row.width { return "portrait" }
        return row.choice.rect.width < CGFloat(row.width) ? "wider than 16:9" : "landscape taller than 16:9"
    }

    private static func csv(_ rows: [Row], widths: [Int]) -> String {
        var lines = [
            (["id", "width", "height", "shape", "faces"] + widths.dropFirst().map { "faces_at_\($0)" }
                + ["centre_cut", "cut", "shift", "slack", "face_boxes"]).joined(separator: ","),
        ]
        for row in rows {
            let boxes = row.faces.map { face in
                String(format: "%.0f %.0f %.0f %.0f %.2f",
                       face.rect.minX, face.rect.minY, face.rect.width, face.rect.height, face.confidence)
            }.joined(separator: ";")
            let fields = ["\"\(row.id.replacingOccurrences(of: "\"", with: "\"\""))\"",
                          "\(row.width)", "\(row.height)", shape(row), "\(row.counts[0])"]
                + row.counts.dropFirst().map(String.init)
                + ["\(row.choice.centreCut)", "\(row.choice.cut)", "\(row.choice.shift)",
                   "\(row.choice.slack)", "\"\(boxes)\""]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func summarise(_ rows: [Row], widths: [Int]) -> [(String, String)] {
        func count(_ test: (Row) -> Bool) -> Int { rows.filter(test).count }
        var lines: [(String, String)] = [("photographs", "\(rows.count)")]
        for name in ["portrait", "landscape taller than 16:9", "wider than 16:9", "16:9"] {
            let ofShape = rows.filter { shape($0) == name }
            guard !ofShape.isEmpty else { continue }
            lines.append((name, "\(ofShape.count): \(ofShape.filter { !$0.faces.isEmpty }.count) with faces, "
                          + "\(ofShape.filter { $0.choice.shift != 0 }.count) windows moved"))
        }
        lines.append(("with faces at \(widths[0]) px", "\(count { !$0.faces.isEmpty })"))
        for (index, width) in widths.enumerated().dropFirst() {
            lines.append(("with faces at \(width) px", "\(count { $0.counts[index] > 0 })"))
            lines.append(("  more faces at \(width) than at \(widths[0])", "\(count { $0.counts[index] > $0.counts[0] })"))
            lines.append(("  fewer faces at \(width) than at \(widths[0])", "\(count { $0.counts[index] < $0.counts[0] })"))
        }
        let moved = rows.filter { $0.choice.shift != 0 }
        lines.append(("windows moved", "\(moved.count)"))
        lines.append(("faces cut, centre → face-aware",
                      "\(rows.reduce(0) { $0 + $1.choice.centreCut }) → \(rows.reduce(0) { $0 + $1.choice.cut }) "
                      + "of \(rows.reduce(0) { $0 + $1.faces.count })"))
        lines.append(("photographs cutting a face, centre → face-aware",
                      "\(count { $0.choice.centreCut > 0 }) → \(count { $0.choice.cut > 0 })"))
        let fractions = moved.map { Double(abs($0.choice.shift)) / Double(max($0.choice.slack, 1)) }.sorted()
        if !fractions.isEmpty {
            lines.append(("move, as a share of the room", String(
                format: "median %.0f%%, p90 %.0f%%, max %.0f%%",
                100 * percentile(fractions, 0.5), 100 * percentile(fractions, 0.9), 100 * fractions.last!
            )))
        }
        return lines
    }

    private static func timingReport(_ rows: [Row], widths: [Int], elapsed: Double, failures: [(String, Error)]) -> String {
        var lines = [String(
            format: "%d photographs in %.1f s, %.1f/s on %d threads (decode + Vision at every width)",
            rows.count, elapsed, Double(rows.count) / max(elapsed, 0.001), ProcessInfo.processInfo.activeProcessorCount
        )]
        let decode = rows.map(\.decodeTime).sorted()
        lines.append(String(format: "  decode at %d px: median %.0f ms, p90 %.0f ms, total %.0f s",
                            widths.max()!, 1000 * percentile(decode, 0.5), 1000 * percentile(decode, 0.9),
                            decode.reduce(0, +)))
        for (index, width) in widths.enumerated() {
            let vision = rows.map { $0.visionTimes[index] }.sorted()
            lines.append(String(format: "  Vision at %d px: median %.0f ms, p90 %.0f ms, total %.0f s",
                                width, 1000 * percentile(vision, 0.5), 1000 * percentile(vision, 0.9),
                                vision.reduce(0, +)))
        }
        lines.append("  times are per photograph with every core busy, as indexing runs")
        for (id, error) in failures.prefix(20) { lines.append("  FAILED \(id): \(error)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    // MARK: - Page

    private static func page(_ rows: [Row], summary: [(String, String)], widths: [Int], folder: String) -> String {
        let moved = rows.filter { $0.choice.shift != 0 }
            .sorted { (abs($0.choice.shift) * 1000 / max($0.choice.slack, 1), $1.id)
                > (abs($1.choice.shift) * 1000 / max($1.choice.slack, 1), $0.id) }
        let stuck = rows.filter { $0.choice.shift == 0 && $0.choice.cut > 0 }
        let disagreeing = rows.filter { $0.choice.shift == 0 && $0.choice.cut == 0 && Set($0.counts).count > 1 }

        func section(_ title: String, _ note: String, _ rows: [Row]) -> String {
            var html = "<h2>\(escape(title)) <span>\(rows.count)</span></h2>\n<p class=\"muted\">\(note)</p>\n"
            for row in rows {
                guard let file = row.file else { continue }
                let faces = row.faces.map { String(format: "%.2f", $0.confidence) }.joined(separator: " ")
                let others = widths.count > 1
                    ? " · at " + zip(widths, row.counts).map { "\($0) px: \($1)" }.joined(separator: ", ")
                    : ""
                html += """
                <div class="row">
                <figure class="whole"><a href="images/\(file)-whole.jpg"><img src="images/\(file)-whole.jpg" loading="lazy" alt=""></a></figure>
                <figure><img src="images/\(file)-centre.jpg" loading="lazy" alt=""><figcaption>centre · cuts \(row.choice.centreCut)</figcaption></figure>
                <figure><img src="images/\(file)-faces.jpg" loading="lazy" alt=""><figcaption>face-aware · cuts \(row.choice.cut) · moved \(row.choice.shift) of ±\(row.choice.slack) px</figcaption></figure>
                </div>
                <p class="caption"><b>\(escape(row.id))</b> · \(row.width)×\(row.height) · \(row.faces.count) faces (confidence \(faces))\(others)</p>

                """
            }
            return html
        }

        let table = summary.map { "<tr><td>\(escape($0.0))</td><td>\(escape($0.1))</td></tr>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Face-aware crop</title>
        <style>
        :root { --bg: #fafaf8; --ink: #1d1d1b; --muted: #6b6b66; --rule: #c9c8c2; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1a; --ink: #ecebe6; --muted: #9a9993; --rule: #4a4a45; } }
        body { background: var(--bg); color: var(--ink); font: 14px/1.4 -apple-system, system-ui, sans-serif; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 40px 0 4px; }
        h2 span, .muted { color: var(--muted); font-weight: normal; }
        table { border-collapse: collapse; margin: 16px 0; font-variant-numeric: tabular-nums; }
        td { padding: 4px 14px 4px 0; border-bottom: 1px solid var(--rule); }
        .row { display: grid; grid-template-columns: auto 1fr 1fr; gap: 8px; align-items: start; margin-top: 20px; }
        .row img { width: 100%; display: block; }
        .row .whole img { width: auto; height: 270px; }
        figure { margin: 0; }
        figcaption, .caption { font-size: 12px; color: var(--muted); margin: 3px 0 0; font-variant-numeric: tabular-nums; }
        .caption b { color: var(--ink); font-weight: 600; }
        .key i { display: inline-block; width: 18px; height: 0; vertical-align: middle; margin: 0 4px 0 12px; }
        </style>
        </head>
        <body>
        <h1>Face-aware crop</h1>
        <p class="muted">\(escape(folder)) · Vision face rectangles, revision \(FaceDetector.revision) · windows chosen at \(widths[0]) px</p>
        <p class="muted key"><i style="border-top: 2px solid #ffd91a"></i>face
        <i style="border-top: 1px dashed #ffd91a"></i>head above it (headroom \(Int(FaceAwareCrop.headroom * 100)) %)
        <i style="border-top: 2px solid #999"></i>face cut by the photograph's frame, not counted
        \(widths.count > 1 ? "<i style=\"border-top: 2px solid #33d9ff\"></i>face found at another width" : "")
        <i style="border-top: 2px dashed #ff4040"></i>centre window
        <i style="border-top: 3px solid #33e64d"></i>face-aware window</p>
        <table>
        \(table)
        </table>
        \(section("Window moved", "Largest move first, as a share of the room the window had.", moved))
        \(section("A face cut either way", "The window stayed: no position keeps more faces whole than the centre does.", stuck))
        \(widths.count > 1 ? section("Widths disagree", "Same window, different faces found at different widths.", disagreeing) : "")
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FaceSpecimen.Row] = []
    private var failed: [(String, Error)] = []

    var rows: [FaceSpecimen.Row] { lock.lock(); defer { lock.unlock() }; return all }
    var failures: [(String, Error)] { lock.lock(); defer { lock.unlock() }; return failed.sorted { $0.0 < $1.0 } }

    func add(_ row: FaceSpecimen.Row) { lock.lock(); all.append(row); lock.unlock() }
    func fail(_ id: String, _ error: Error) { lock.lock(); failed.append((id, error)); lock.unlock() }
}
