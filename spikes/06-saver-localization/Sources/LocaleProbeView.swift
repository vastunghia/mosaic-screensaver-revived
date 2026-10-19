// Spike 6 — the screen saver side of the probe. It logs every line and draws them on
// screen, so that the preview in System Settings can be read with a screenshot too.
//   /usr/bin/log show --predicate 'subsystem == "dev.mosaic.spike" AND category == "locale"' --last 10m

import ScreenSaver
import AppKit
import os

private let osLog = OSLog(subsystem: "dev.mosaic.spike", category: "locale")

@objc(LocaleProbeView)
final class LocaleProbeView: ScreenSaverView {

    private let lines: [String]

    override init?(frame: NSRect, isPreview: Bool) {
        lines = Probe.run(bundle: Bundle(for: LocaleProbeView.self))
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0
        os_log("probe start — preview=%{public}@", log: osLog, type: .default, "\(isPreview)")
        for line in lines {
            os_log("probe %{public}@", log: osLog, type: .default, line)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let size: CGFloat = isPreview ? 7 : 16
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        var y = bounds.maxY - size * 2
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: size, y: y), withAttributes: attributes)
            y -= size * 1.4
        }
    }
}
