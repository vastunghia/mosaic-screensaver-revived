import AppKit
import Metal
import MosaicEngine
import QuartzCore
import os

/// The effect itself, small, at the top of the window: the same engine as
/// full screen, on 256 photographs and without close-ups, as the screen saver's
/// own preview (a window a few hundred points wide shows no difference).
///
/// It draws only while its window is on screen. In the app, unlike inside
/// `legacyScreenSaver`, the window's occlusion state is reliable, and a
/// window covered, minimised, hidden or behind the player lets its engine go.
final class PreviewMetalView: NSView {
    /// Builds the engine, off the main thread. Nil: nothing to show yet.
    var makeEngine: (@Sendable (MTLDevice) throws -> MosaicEngine)? {
        didSet { restart() }
    }

    var onClick: (() -> Void)?

    private var engine: MosaicEngine?
    private var link: CADisplayLink?
    private var time: TimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    /// Bumped by every start and stop, so an engine that finishes building
    /// after its run has ended is dropped.
    private var generation = 0
    private var occlusionObserver: NSObjectProtocol?

    nonisolated private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override var isOpaque: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: Running only while seen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
        }
        restart()
    }

    private var shouldRun: Bool {
        makeEngine != nil && window?.occlusionState.contains(.visible) == true
    }

    /// Starts, stops, or starts again with what `makeEngine` now builds.
    private func restart() {
        let running = engine != nil || link != nil
        if running || !shouldRun { stop() }
        if shouldRun { start() }
    }

    private func start() {
        guard let makeEngine, layer is CAMetalLayer else { return }
        generation += 1
        let run = generation
        let display = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
        guard let device = display.flatMap(CGDirectDisplayCopyCurrentMetalDevice) ?? MTLCreateSystemDefaultDevice()
        else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let box = EngineBox()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                box.engine = try makeEngine(device)
            } catch {
                Self.log.error("the window's preview could not start: \(error, privacy: .public)")
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    // The layer is read again here rather than carried through
                    // the background thread, which must not touch it.
                    guard let self, self.generation == run, let engine = box.engine,
                          let metalLayer = self.layer as? CAMetalLayer else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    Self.log.notice("window preview started in \(elapsed, format: .fixed(precision: 2), privacy: .public) s")
                    self.begin(engine, on: metalLayer)
                }
            }
        }
    }

    private func begin(_ engine: MosaicEngine, on metalLayer: CAMetalLayer) {
        self.engine = engine
        time = 0
        lastTimestamp = nil
        engine.attach(to: metalLayer, size: drawableSize())
        if let fps = window?.screen?.maximumFramesPerSecond, fps > 0 {
            engine.refreshInterval = 1.0 / Double(fps)
        }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        generation += 1
        link?.invalidate()
        link = nil
        if engine != nil { Self.log.notice("window preview stopped") }
        engine = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        MainActor.assumeIsolated {
            guard let engine else { return }
            let delta = lastTimestamp.map { now - $0 } ?? 0
            // As full screen and in the saver: the clock holds while the
            // engine is not ready for the instant it would move to.
            let next = time + min(delta, 0.25)
            guard engine.isReady(at: next) else {
                lastTimestamp = nil
                if engine.isReady(at: time) { engine.advance(to: time) }
                return
            }
            time = next
            lastTimestamp = now
            engine.advance(to: time)
        }
    }

    // MARK: Geometry

    private func drawableSize() -> CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        engine?.resize(drawableSize())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        engine?.resize(drawableSize())
    }
}

/// Carries the engine from the thread that builds it to the main thread.
private final class EngineBox: @unchecked Sendable {
    var engine: MosaicEngine?
}
