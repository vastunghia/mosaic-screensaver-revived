import AppKit
import MosaicEngine
import QuartzCore
import SwiftUI

/// The view the effect is drawn into: a CAMetalLayer and a display link, and
/// nothing else. Every frame is `engine.advance(to:)` — the same call the screen
/// saver will make from `animateOneFrame`.
final class MosaicMetalView: NSView {
    private let engine: MosaicEngine
    private let clock: HarnessClock
    private let readout: HarnessReadout
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var smoothedFPS: Double = 0
    private var lastReadoutUpdate: CFTimeInterval = 0
    private var lastLoggedCycle = -1

    init(engine: MosaicEngine, clock: HarnessClock, readout: HarnessReadout) {
        self.engine = engine
        self.clock = clock
        self.readout = readout
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let metalLayer = layer as? CAMetalLayer else { return }

        if window != nil {
            engine.attach(to: metalLayer, size: drawableSize())
            // macOS 14 and later: a display link tied to this view, which
            // follows the refresh rate of the screen the window is actually on.
            // That matters here — the displays on this machine do not all run at
            // the same rate.
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .current, forMode: .common)
            self.link = link
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeDrawable()
    }

    private func drawableSize() -> CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    private func resizeDrawable() {
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        engine.resize(drawableSize())
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        MainActor.assumeIsolated {
            if let last = lastTimestamp {
                let delta = now - last
                if delta > 0 {
                    // Heavily smoothed: an unsteady number in the corner reads
                    // as a problem with the effect even when it is a problem
                    // with the number.
                    smoothedFPS += (1 / delta - smoothedFPS) * 0.1
                }
                clock.advance(by: min(delta, 0.25))
            }
            lastTimestamp = now
            engine.advance(to: clock.time)

            // The overlay is refreshed a few times a second, not every frame:
            // redrawing SwiftUI at 60 Hz would compete with the thing being
            // measured.
            if now - lastReadoutUpdate > 0.25 {
                lastReadoutUpdate = now
                readout.publish(framesPerSecond: smoothedFPS, statistics: engine.statistics)
            }

            // One line per cycle on stdout, so a run can be read back without
            // anyone watching the overlay: a stall count that grows while the
            // effect simply runs means the lookahead is late.
            let statistics = engine.statistics
            if statistics.cycleIndex != lastLoggedCycle {
                lastLoggedCycle = statistics.cycleIndex
                print(String(
                    format: "cycle %d · %d stalls · %.0f fps · %@",
                    statistics.cycleIndex, statistics.stalls, smoothedFPS, statistics.deviceName
                ))
                fflush(stdout)
            }
        }
    }
}

struct MosaicView: NSViewRepresentable {
    let engine: MosaicEngine
    let clock: HarnessClock
    let readout: HarnessReadout

    func makeNSView(context: Context) -> MosaicMetalView {
        MosaicMetalView(engine: engine, clock: clock, readout: readout)
    }

    func updateNSView(_ view: MosaicMetalView, context: Context) {}
}
