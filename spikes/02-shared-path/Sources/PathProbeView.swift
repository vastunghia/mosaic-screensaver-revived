// SAVER side of spike 2.
//
// It runs inside legacyScreenSaver, inherits its sandbox, and tries to read back the markers
// left by the app side. It also draws the outcome on screen, so that the result is visible
// without having to read the log.

import ScreenSaver
import AppKit

@objc(PathProbeView)
final class PathProbeView: ScreenSaverView {

    private var lines: [String] = []

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0
        if !isPreview { run() }   // pointless in preview: same process, same outcome
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func run() {
        let home = realHomeDirectory()
        say("SPIKE2 ===== SAVER side =====")
        say("SPIKE2 saver  pid=\(ProcessInfo.processInfo.processIdentifier)")
        say("SPIKE2 saver  NSHomeDirectory=\(NSHomeDirectory())")
        say("SPIKE2 saver  real home inferred=\(home)")
        say("SPIKE2 saver  sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "(none)")")

        for c in candidates(realHome: home) {
            // 1. can I read back what the app wrote?
            let (rOutcome, rDetail) = tryRead(dir: c.dir, fileName: "app-marker.txt")
            say(line("saver", c.name, "read", rOutcome, rDetail))
            lines.append("\(c.name)  read: \(rOutcome.rawValue)")

            // 2. and can I write there myself?
            let (wOutcome, wDetail) = tryWrite(dir: c.dir, fileName: "saver-marker.txt",
                                               content: "spike2-saver")
            say(line("saver", c.name, "write", wOutcome, wDetail))
            lines[lines.count - 1] += "   write: \(wOutcome.rawValue)"
        }
        say("SPIKE2 saver  done")
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
        guard !isPreview else {
            ("SPIKE 2" as NSString).draw(at: NSPoint(x: 6, y: bounds.midY),
                withAttributes: [.foregroundColor: NSColor.white,
                                 .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)])
            return
        }
        let text = (["SPIKE 2 — shared path app ↔ saver", ""] + lines
                    + ["", "The details are in the unified log."]).joined(separator: "\n")
        (text as NSString).draw(in: bounds.insetBy(dx: 60, dy: 60), withAttributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
        ])
    }

    override func animateOneFrame() { setNeedsDisplay(bounds) }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
