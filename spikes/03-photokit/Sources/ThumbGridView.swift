// SAVER side of spike 3.
//
// One question only: are the thumbnails the app extracted from the Photos library readable
// and usable from inside the legacyScreenSaver sandbox, without any authorisation?
// The saver does not import Photos and asks no one for anything: it reads files, as spike 2
// showed it can.

import ScreenSaver
import AppKit

@objc(ThumbGridView)
final class ThumbGridView: ScreenSaverView {

    private var images: [NSImage] = []
    private var colours: [NSColor] = []
    private var diagnostic = "waiting"

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0
        if !isPreview { load() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func load() {
        say("SPIKE3 ===== SAVER side =====")
        say("SPIKE3 saver  pid=\(ProcessInfo.processInfo.processIdentifier)")
        say("SPIKE3 saver  looking for the index in \(indexFile)")

        guard let data = FileManager.default.contents(atPath: indexFile) else {
            diagnostic = "index not readable: \(indexFile)"
            say("SPIKE3 saver  INDEX NOT READABLE")
            return
        }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else {
            diagnostic = "index unreadable (invalid JSON)"
            say("SPIKE3 saver  JSON could not be decoded")
            return
        }
        say("SPIKE3 saver  index read: \(index.entries.count) entries, library of \(index.libraryTotal)")

        var loaded = 0
        var failed = 0
        for entry in index.entries.prefix(120) {
            let path = thumbsDirectory + "/" + entry.file
            if let img = NSImage(contentsOfFile: path) {
                images.append(img)
                colours.append(NSColor(red: entry.r, green: entry.g, blue: entry.b, alpha: 1))
                loaded += 1
            } else {
                failed += 1
            }
        }
        diagnostic = "\(loaded) thumbnails loaded, \(failed) failed — library: \(index.libraryTotal)"
        say("SPIKE3 saver  \(diagnostic)")
        say("SPIKE3 saver  done")
    }

    /// A grid of thumbnails with, under each one, a strip of its average colour: if the two
    /// match, the colour computation crossed the boundary intact as well.
    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()

        guard !isPreview else {
            ("SPIKE 3" as NSString).draw(at: NSPoint(x: 6, y: bounds.midY), withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)])
            return
        }

        let header = "SPIKE 3 — PhotoKit thumbnails read inside the sandbox\n\(diagnostic)"
        (header as NSString).draw(in: bounds.insetBy(dx: 40, dy: 20).offsetBy(dx: 0, dy: bounds.height / 2 - 60),
            withAttributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)])

        guard !images.isEmpty else { return }

        let columns = 12
        let rows = max(1, Int(ceil(Double(images.count) / Double(columns))))
        let area = bounds.insetBy(dx: 40, dy: 40)
        let area2 = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - 70)
        let w = area2.width / CGFloat(columns)
        let h = area2.height / CGFloat(rows)

        for (i, img) in images.enumerated() {
            let c = i % columns, r = i / columns
            let cell = NSRect(x: area2.minX + CGFloat(c) * w,
                              y: area2.maxY - CGFloat(r + 1) * h,
                              width: w, height: h).insetBy(dx: 2, dy: 2)
            let stripH = max(3, cell.height * 0.12)
            let photo = NSRect(x: cell.minX, y: cell.minY + stripH, width: cell.width,
                               height: cell.height - stripH)
            img.draw(in: photo, from: .zero, operation: .copy, fraction: 1.0)
            colours[i].setFill()
            NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: stripH).fill()
        }
    }

    override func animateOneFrame() { setNeedsDisplay(bounds) }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
