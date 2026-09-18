// Spike 1 — Metal inside legacyScreenSaver.
//
// The question this code has to answer: can a third-party .saver draw with Metal inside
// the sandboxed `legacyScreenSaver` process? At what rate? With which diagnostics?
//
// This is not production code: everything that matters goes to os_log, and is read with
//   log stream --predicate 'subsystem == "dev.mosaic.spike"' --style compact

import ScreenSaver
import Metal
import QuartzCore
import AppKit
import os

/// The unified log is the only channel readable from inside `legacyScreenSaver`: there is
/// no stdout and no stderr in there. It is read with:
///   /usr/bin/log stream --predicate 'subsystem == "dev.mosaic.spike"' --style compact
private let osLog = OSLog(subsystem: "dev.mosaic.spike", category: "metal")

private func spike(_ message: String, error: Bool = false) {
    // `type:` must be a literal, not an expression.
    if error {
        os_log("%{public}@", log: osLog, type: .error, message)
    } else {
        os_log("%{public}@", log: osLog, type: .default, message)
    }
    FileHandle.standardError.write(("SPIKE: " + message + "\n").data(using: .utf8)!)
}

private struct Uniforms {
    var angle: Float
    var aspect: Float
}

@objc(MetalSpikeView)
final class MetalSpikeView: ScreenSaverView {

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?

    /// If setup fails we keep the reason and draw it on screen, because in a screen saver
    /// a black screen is indistinguishable from a thousand different causes.
    private var failureReason: String?

    private let started = CACurrentMediaTime()
    private var framesSinceReport = 0
    private var lastReport = CACurrentMediaTime()
    private var gpuTimeAccumulator: Double = 0
    private var gpuSamples = 0
    private var drawableFailures = 0

    // MARK: - Life cycle

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        logEnvironment(isPreview: isPreview, frame: frame)
        setUpMetal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func logEnvironment(isPreview: Bool, frame: NSRect) {
        let p = ProcessInfo.processInfo
        spike("""
            start — process=\(p.processName) pid=\(p.processIdentifier) \
            preview=\(isPreview) frame=\(Int(frame.width))x\(Int(frame.height)) \
            macOS=\(p.operatingSystemVersionString)
            """)
        // Knowing whether we are sandboxed, and in which container, changes everything
        // for spike 2.
        let env = p.environment
        spike("""
            sandbox: APP_SANDBOX_CONTAINER_ID=\(env["APP_SANDBOX_CONTAINER_ID"] ?? "(none)") \
            HOME=\(NSHomeDirectory())
            """)
    }

    private func setUpMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("MTLCreateSystemDefaultDevice() returned nil — no Metal device visible to the process")
            return
        }
        self.device = device
        spike("""
            device=\(device.name) low-power=\(device.isLowPower) \
            removable=\(device.isRemovable) unified-memory=\(device.hasUnifiedMemory) \
            max-buffer=\(device.maxBufferLength / (1024 * 1024))MB
            """)

        guard let queue = device.makeCommandQueue() else {
            fail("makeCommandQueue() returned nil")
            return
        }
        self.queue = queue

        // A precompiled metallib: it is the production path, and above all it avoids
        // confusing "Metal does not work here" with "the shader compilation service is
        // unreachable from the sandbox".
        let bundle = Bundle(for: MetalSpikeView.self)
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: bundle)
        } catch {
            fail("makeDefaultLibrary(bundle:) failed: \(error.localizedDescription)")
            return
        }

        guard let vfn = library.makeFunction(name: "spike_vertex"),
              let ffn = library.makeFunction(name: "spike_fragment") else {
            fail("shader functions not found in the metallib")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fail("makeRenderPipelineState failed: \(error.localizedDescription)")
            return
        }

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        layer.frame = bounds
        self.metalLayer = layer
        self.layer = layer
        self.wantsLayer = true
        updateDrawableSize()

        spike("Metal setup complete")
    }

    private func fail(_ reason: String) {
        failureReason = reason
        spike("SETUP FAILED: \(reason)", error: true)
    }

    // MARK: - Geometry

    private func updateDrawableSize() {
        guard let layer = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        layer.contentsScale = scale
        layer.frame = bounds
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0 && size.height > 0 {
            layer.drawableSize = size
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    // MARK: - Animation

    override func startAnimation() {
        super.startAnimation()
        spike("startAnimation")
    }

    override func stopAnimation() {
        super.stopAnimation()
        spike("""
            stopAnimation — frames reported so far, drawable nil \(self.drawableFailures) times
            """)
    }

    override func animateOneFrame() {
        guard failureReason == nil else {
            setNeedsDisplay(bounds)
            return
        }
        draw()
        report()
    }

    private func draw() {
        guard let layer = metalLayer,
              let queue = queue,
              let pipeline = pipeline else { return }

        guard let drawable = layer.nextDrawable() else {
            // The typical symptom of a layer not attached to anything visible.
            drawableFailures += 1
            if drawableFailures % 60 == 1 {
                spike("nextDrawable() nil (occurrence \(self.drawableFailures))", error: true)
            }
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = layer.drawableSize
        var uniforms = Uniforms(
            angle: Float((CACurrentMediaTime() - started) * 0.8),
            aspect: Float(size.height > 0 ? size.width / size.height : 1)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        buffer.addCompletedHandler { [weak self] done in
            guard let self else { return }
            let gpu = done.gpuEndTime - done.gpuStartTime
            if gpu > 0 {
                self.gpuTimeAccumulator += gpu
                self.gpuSamples += 1
            }
        }
        buffer.present(drawable)
        buffer.commit()
        framesSinceReport += 1
    }

    /// One line per second: effective rate and average GPU time per frame.
    private func report() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastReport
        guard elapsed >= 1.0 else { return }
        let fps = Double(framesSinceReport) / elapsed
        let gpuMs = gpuSamples > 0 ? (gpuTimeAccumulator / Double(gpuSamples)) * 1000 : -1
        spike("""
            fps=\(String(format: "%.1f", fps)) \
            gpu=\(String(format: "%.3f", gpuMs))ms/frame \
            samples=\(self.gpuSamples)
            """)
        framesSinceReport = 0
        gpuTimeAccumulator = 0
        gpuSamples = 0
        lastReport = now
    }

    // MARK: - Legible fallback

    override func draw(_ rect: NSRect) {
        guard let reason = failureReason else { return }
        NSColor.black.setFill()
        rect.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "Metal spike — SETUP FAILED\n\n\(reason)" as NSString
        text.draw(in: bounds.insetBy(dx: 40, dy: bounds.height / 2 - 60), withAttributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: isPreview ? 7 : 20, weight: .regular),
            .paragraphStyle: style,
        ])
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
