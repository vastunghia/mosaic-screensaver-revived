import AppKit
import Metal
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
    private var lastLoggedRebuilds = 0

    private let drawableScale: Double

    init(engine: MosaicEngine, clock: HarnessClock, readout: HarnessReadout, drawableScale: Double = 1) {
        self.engine = engine
        self.clock = clock
        self.readout = readout
        self.drawableScale = drawableScale
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

        if let window {
            engine.attach(to: metalLayer, size: drawableSize())
            PacingProbe.shared.start()
            PacingProbe.shared.watch(window)
            if let fps = window.screen?.maximumFramesPerSecond, fps > 0 {
                engine.refreshInterval = 1.0 / Double(fps)
            }
            engine.onFreeze = { freeze in
                print(freeze.description)
                fflush(stdout)
                PacingProbe.shared.describe(freeze)
            }
            // Should the GPU go away, rebuild on the one driving this window's
            // display: with an eGPU attached, the system default is not
            // necessarily it.
            if let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let display = CGDirectDisplayID(number.uint32Value)
                engine.deviceProvider = { _ in CGDirectDisplayCopyCurrentMetalDevice(display) }
            }
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
        let scale = (window?.backingScaleFactor ?? 2) * drawableScale
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    private func resizeDrawable() {
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        engine.resize(drawableSize())
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        MainActor.assumeIsolated {
            let delta = lastTimestamp.map { now - $0 } ?? 0

            // The clock does not move while the engine is not ready for the
            // instant it would move to — before the first cycle, across a join
            // whose close-ups are late, while it rebuilds itself on another
            // GPU — so the effect waits where it is rather than drawing late.
            // At a join the zoom is at rest, and a short wait there does not
            // show. Exactly what the .saver will do.
            let next = clock.isPaused ? clock.time : clock.time + min(delta, 0.25)
            guard engine.isReady(at: next) else {
                lastTimestamp = nil
                if engine.isReady(at: clock.time) { engine.advance(to: clock.time) }
                return
            }
            if delta > 0 {
                // Heavily smoothed: an unsteady number in the corner reads as a
                // problem with the effect even when it is a problem with the
                // number.
                smoothedFPS += (1 / delta - smoothedFPS) * 0.1
            }
            clock.advance(by: min(delta, 0.25))
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
            if statistics.rebuilds != lastLoggedRebuilds {
                lastLoggedRebuilds = statistics.rebuilds
                print(String(
                    format: "rebuilt on %@ in %.2f s (rebuild %d)",
                    statistics.deviceName, statistics.lastRebuildSeconds, statistics.rebuilds
                ))
            }
            if statistics.cycleIndex != lastLoggedCycle {
                lastLoggedCycle = statistics.cycleIndex
                print(String(
                    format: "cycle %d · %d stalls · %d close-up misses · %d freezes · %.0f MB close-ups · %.0f fps · %@",
                    statistics.cycleIndex, statistics.stalls, statistics.closeUpMisses, statistics.freezes,
                    Double(statistics.closeUpBytes) / 1_048_576, smoothedFPS, statistics.deviceName
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
    var drawableScale: Double = 1

    func makeNSView(context: Context) -> MosaicMetalView {
        MosaicMetalView(engine: engine, clock: clock, readout: readout, drawableScale: drawableScale)
    }

    func updateNSView(_ view: MosaicMetalView, context: Context) {}
}
