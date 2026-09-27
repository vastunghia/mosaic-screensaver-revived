import CoreGraphics
import CycleEngine
import Metal
import MosaicCore
import MosaicPhotos
import MosaicRender
import MosaicSolver
import QuartzCore
import TileStore

public enum MosaicEngineError: Error {
    case noCommandQueue
    case emptyPhotoSource
    case noDevice
}

/// M8: the only class a host instantiates, and the public boundary of the whole
/// library.
///
/// Nothing above this line may be needed to run the effect. The app and the
/// .saver are two thin shells over exactly this API — if one of them ever needs
/// a shortcut the other cannot take, that is an architecture bug and not a
/// convenience.
public final class MosaicEngine {
    public private(set) var settings: MosaicSettings

    /// Everything that belongs to the current MTLDevice. Replaced whole when
    /// that device goes away; read and swapped on the host's thread only.
    private var gpu: GPUResources
    private let recipe: GPUResources.Recipe

    private let lookahead: Lookahead
    /// Close-up misses of the GPU resources already thrown away, so the count
    /// survives a rebuild.
    private var earlierCloseUpMisses = 0
    private let closeUpRing: Int
    private let tilePixelWidth: Int

    private var cycle: CycleEngine

    private var layer: CAMetalLayer?
    private let statisticsBox = StatisticsBox()

    /// The rebuild in progress, shared with the thread that does it and with
    /// whichever thread Metal reports a device removal on.
    private let rebuildLock = NSLock()
    private var rebuilding = false
    private var replacement: GPUResources?
    private var currentDeviceID: UInt64
    private var deviceObserver: NSObjectProtocol?

    /// Which device to rebuild on when the current one goes away, given the one
    /// lost (nil for a rebuild asked for by hand). A host that knows which
    /// display it draws on answers with the GPU driving that display
    /// (`CGDirectDisplayCopyCurrentMetalDevice`); nil, or the lost device
    /// itself, falls back to any device still attached. Called off the main
    /// thread.
    public var deviceProvider: (@Sendable (MTLDevice?) -> MTLDevice?)? {
        get { rebuildLock.lock(); defer { rebuildLock.unlock() }; return provider }
        set { rebuildLock.lock(); provider = newValue; rebuildLock.unlock() }
    }
    private var provider: (@Sendable (MTLDevice?) -> MTLDevice?)?

    /// - Parameter library: normally nil, and then the engine resolves
    ///   default.metallib from the bundle its own code lives in — the app or the
    ///   .saver, without either having to say which. A host passes one in only
    ///   when it has compiled the shaders some other way, which is what the
    ///   development harness does when it runs outside a bundle.
    /// - Parameters:
    ///   - closeUpSource: where the tiles that grow bigger than an atlas slice
    ///     get their pixels. Nil draws everything from the atlas. The app passes
    ///     a source with originals behind it; the index alone is exactly what
    ///     the .saver has.
    ///   - closeUpRing: how far from the anchor, in cells, close-ups are made.
    ///     0 is the anchor alone.
    public init(
        device: MTLDevice,
        settings: MosaicSettings = MosaicSettings(),
        source: PhotoSource = SyntheticPhotoSource(),
        planner: (any MosaicPlanner)? = nil,
        library: MTLLibrary? = nil,
        seed: UInt64 = 0x4D05_A1C0,
        tilePixelWidth: Int = 256,
        closeUpSource: (any PhotoSource)? = nil,
        closeUpRing: Int = 0
    ) throws {
        let descriptors = try source.photos()
        guard !descriptors.isEmpty else {
            throw MosaicEngineError.emptyPhotoSource
        }

        self.settings = settings
        self.cycle = CycleEngine(settings: settings)
        let fallback = RandomMosaicPlanner(pool: descriptors.map(\.id), seed: seed)
        self.lookahead = Lookahead(
            planner: planner ?? fallback, fallback: fallback, seed: seed, rows: settings.rows
        )
        self.recipe = GPUResources.Recipe(
            source: source,
            photos: descriptors.map(\.id),
            tileWidth: tilePixelWidth,
            closeUpSource: closeUpSource
        )
        self.gpu = try GPUResources(device: device, library: library, recipe: recipe)
        self.currentDeviceID = device.registryID
        self.closeUpRing = max(0, closeUpRing)
        self.tilePixelWidth = tilePixelWidth
        statisticsBox.update { $0.deviceName = device.name }

        // An eGPU can be unplugged while the effect runs. Metal says so, on a
        // thread of its choosing, both when removal is requested (the eject
        // item in the menu bar, which waits for us to let go) and when the
        // device is simply gone.
        let (_, observer) = MTLCopyAllDevicesWithObserver { [weak self] device, notification in
            guard notification == .removalRequested || notification == .wasRemoved else { return }
            self?.deviceWentAway(device)
        }
        self.deviceObserver = observer

        // The first cycle a host normally shows, started now so that it is
        // likely to be ready by the first frame.
        lookahead.prefetch(0)
        lookahead.prefetch(1)
    }

    deinit {
        if let deviceObserver { MTLRemoveDeviceObserver(deviceObserver) }
    }

    // MARK: - Host API

    /// The MTLDevice drawing now. It changes if that one goes away.
    public var device: MTLDevice { gpu.device }

    public func attach(to layer: CAMetalLayer, size: CGSize) {
        layer.device = gpu.device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.isOpaque = true
        self.layer = layer
        resize(size)
    }

    public func resize(_ size: CGSize) {
        guard let layer, size.width > 0, size.height > 0 else { return }
        layer.drawableSize = size
    }

    public func updateSettings(_ settings: MosaicSettings) {
        // Only R invalidates the layouts; the curve and the crossfade are read
        // fresh every frame. Checking is not a micro-optimisation now that a
        // layout is a solved photomosaic: dragging the duration slider would
        // otherwise re-solve the mosaic at slider rate.
        let rowsChanged = settings.rows != self.settings.rows
        self.settings = settings
        self.cycle = CycleEngine(settings: settings)
        if rowsChanged {
            lookahead.reset(rows: settings.rows)
            // Close-ups belong to a cycle's layout, and those just changed.
            gpu.closeUps?.evict(before: .max)
        }
    }

    /// Whether the frame at `time` can be drawn as it should be: its mosaics
    /// built and its close-ups loaded. Asking starts whatever is missing.
    ///
    /// A host calls this before its first frame and holds its clock until it
    /// says yes. Drawing earlier is not wrong, only worse: a cycle fixes its
    /// close-ups the first time it is drawn, so a first frame drawn too soon
    /// leaves the whole first cycle to the atlas.
    ///
    /// It also says no while the engine is rebuilding itself on another GPU,
    /// so a host that asks every frame holds its clock through that too, and
    /// the effect resumes where it stopped rather than further on.
    public func isReady(at time: TimeInterval) -> Bool {
        guard adoptReplacement() else { return false }
        let index = cycle.position(at: time).index
        lookahead.prefetch(index)
        if index > 0 { lookahead.prefetch(index - 1) }
        guard lookahead.isReady(index), index == 0 || lookahead.isReady(index - 1) else {
            return false
        }
        guard let store = gpu.closeUps else { return true }
        if store.isLatched(index) { return true }
        guard let layer, layer.drawableSize.width > 0 else { return false }
        if !store.isRequested(index) {
            let layout = lookahead.mosaic(forCycle: index, counting: false).planned.layout
            store.request(
                cycle: index,
                widths: closeUpWidths(of: layout, screenWidth: Int(layer.drawableSize.width))
            )
        }
        return store.isComplete(index)
    }

    /// Draws the frame for an absolute time. There is no internal clock: the
    /// host owns time, which is what lets the harness scrub it.
    public func advance(to time: TimeInterval) {
        guard adoptReplacement(), let layer, let drawable = layer.nextDrawable() else { return }
        let gpu = gpu

        let (frame, closeUps) = frameState(
            at: time, onScreen: true, screenWidth: Int(layer.drawableSize.width)
        )

        // Bounded, because a frame in flight on a device that has just been
        // unplugged may never complete; the frame is skipped instead.
        guard gpu.inFlight.wait(timeout: .now() + 0.25) == .success else { return }
        guard let commands = gpu.queue.makeCommandBuffer() else {
            gpu.inFlight.signal()
            return
        }
        commands.addCompletedHandler { [inFlight = gpu.inFlight, statisticsBox] buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            statisticsBox.update { $0.gpuMilliseconds = milliseconds }
            inFlight.signal()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            let drawn = gpu.renderer.encode(frame, atlas: gpu.atlas, closeUps: closeUps, into: encoder)
            encoder.endEncoding()
            statisticsBox.update {
                $0.tileCount = drawn
                $0.cycleIndex = frame.position.index
                $0.u = frame.position.u
            }
        }

        commands.present(drawable)
        commands.commit()
    }

    /// The same frame, drawn into a texture instead of onto a screen. This is
    /// what makes everything else verifiable: a cycle can be exported frame by
    /// frame and looked at cold.
    public func renderFrame(at time: TimeInterval, into texture: MTLTexture) {
        let (frame, closeUps) = frameState(at: time, onScreen: false, screenWidth: texture.width)
        render(frame, closeUps: closeUps, into: texture)
    }

    /// One mosaic, filling the screen, and nothing else drawn.
    ///
    /// No new rendering path is needed for it, which is worth saying because the
    /// obvious reading is that there should be. At `u → 1` the camera's visible
    /// width is `R^(ease(1) − 1) = 1`, so the mosaic exactly fills the frame, and
    /// the crossfade has long finished, so the previous cycle is a flat
    /// photograph in the anchor cell. That frame *is* the mosaic.
    ///
    /// What it does skip is the lookahead: `frameState` asks for the next cycle
    /// too, which for a still doubles the work for nothing.
    @discardableResult
    public func renderMosaic(cycle index: Int, into texture: MTLTexture) -> PhotoID {
        lookahead.evict(before: index - 1)
        let current = mosaic(forCycle: index, onScreen: false)
        let previous = index > 0 ? mosaic(forCycle: index - 1, onScreen: false).planned.layout : nil
        let time = (Double(index) + 1 - 1e-9) * settings.cycleDuration
        report(current)
        render(
            cycle.frame(at: time, current: current.planned.layout, previous: previous),
            into: texture
        )
        return current.planned.layout.subject
    }

    private func render(
        _ frame: FrameState,
        closeUps: [PhotoID: MTLTexture] = [:],
        into texture: MTLTexture
    ) {
        guard let commands = gpu.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            gpu.renderer.encode(frame, atlas: gpu.atlas, closeUps: closeUps, into: encoder)
            encoder.endEncoding()
        }

        if texture.storageMode == .managed,
           let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }

        commands.commit()
        commands.waitUntilCompleted()
    }

    public func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        return gpu.device.makeTexture(descriptor: descriptor)
    }

    /// The MTLDevice actually in use, so measurements can be labelled with it.
    /// A Radeon Pro 560X and an RX 6800 are far too different for an unlabelled
    /// frame time to mean anything.
    public var deviceName: String { gpu.device.name }

    public var statistics: FrameStatistics { statisticsBox.current }

    // MARK: - Another GPU

    /// Throws away every GPU resource and makes it again, on the device the
    /// provider names — the same one, when asked by hand, which exercises the
    /// whole path without unplugging anything. The host sees `isReady` say no
    /// until it is done.
    public func rebuild() {
        startRebuild(avoiding: nil)
    }

    private func deviceWentAway(_ lost: MTLDevice) {
        rebuildLock.lock()
        let ours = lost.registryID == currentDeviceID
        rebuildLock.unlock()
        if ours { startRebuild(avoiding: lost) }
    }

    private func startRebuild(avoiding lost: MTLDevice?) {
        rebuildLock.lock()
        guard !rebuilding else {
            rebuildLock.unlock()
            return
        }
        rebuilding = true
        let provider = provider
        rebuildLock.unlock()

        let recipe = recipe
        let statisticsBox = statisticsBox
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            var device = provider?(lost)
            if device == nil || device?.registryID == lost?.registryID {
                device = GPUResources.survivingDevice(avoiding: lost)
            }

            var fresh: GPUResources?
            do {
                guard let device else { throw MosaicEngineError.noDevice }
                fresh = try GPUResources(device: device, library: nil, recipe: recipe)
            } catch {
                statisticsBox.update { $0.lastError = "could not rebuild on another GPU: \(error)" }
            }

            guard let self else { return }
            let seconds = Date().timeIntervalSince(started)
            self.rebuildLock.lock()
            self.replacement = fresh
            if fresh == nil { self.rebuilding = false }
            self.rebuildLock.unlock()
            if let fresh {
                statisticsBox.update {
                    $0.rebuilds += 1
                    $0.lastRebuildSeconds = seconds
                    $0.deviceName = fresh.device.name
                }
            }
        }
    }

    /// Swaps in a rebuilt set of GPU resources, on the host's thread, which is
    /// the only one that touches `gpu`.
    ///
    /// - Returns: false while a rebuild is still running, when nothing may be
    ///   drawn: the old device may already be gone.
    private func adoptReplacement() -> Bool {
        rebuildLock.lock()
        let fresh = replacement
        let busy = rebuilding
        if let fresh {
            replacement = nil
            rebuilding = false
            currentDeviceID = fresh.device.registryID
        }
        rebuildLock.unlock()

        if let fresh {
            earlierCloseUpMisses += gpu.closeUps?.misses ?? 0
            gpu = fresh
            layer?.device = fresh.device
            return true
        }
        return !busy
    }

    // MARK: - Lookahead

    /// - Parameter onScreen: whether this frame is on its way to a display. A
    ///   mosaic missing there is a stall; offscreen rendering waits by design.
    private func frameState(
        at time: TimeInterval,
        onScreen: Bool,
        screenWidth: Int
    ) -> (FrameState, [PhotoID: MTLTexture]) {
        let index = cycle.position(at: time).index

        // SPEC § 2 wants the tiles to look as though they had always been there,
        // so nothing may be built while it is on screen: the next cycle is
        // started now, in the background, a whole cycle before it is needed.
        // Offscreen there is no hurry and no thread to spare the work.
        if onScreen {
            for needed in cycle.cyclesNeeded(at: time) where needed != index {
                lookahead.prefetch(needed)
            }
        }
        lookahead.evict(before: index - 1)

        let current = mosaic(forCycle: index, onScreen: onScreen)
        let previous = index > 0 ? mosaic(forCycle: index - 1, onScreen: onScreen) : nil
        let frame = cycle.frame(
            at: time,
            current: current.planned.layout,
            previous: previous?.planned.layout
        )
        report(current)
        return (frame, closeUps(forCycle: index, layout: current.planned.layout, onScreen: onScreen, screenWidth: screenWidth))
    }

    /// The close-ups the frame draws with, and the next cycle's, started.
    ///
    /// The next cycle's are asked for as soon as its layout exists, which the
    /// lookahead makes a whole cycle ahead of time. On screen, whatever is not
    /// ready when a cycle begins stays an atlas slice for all of that cycle;
    /// offscreen, the frame waits for them.
    private func closeUps(
        forCycle index: Int, layout: MosaicLayout, onScreen: Bool, screenWidth: Int
    ) -> [PhotoID: MTLTexture] {
        guard let store = gpu.closeUps, screenWidth > 0 else { return [:] }
        store.evict(before: index)

        if !store.isRequested(index) {
            store.request(cycle: index, widths: closeUpWidths(of: layout, screenWidth: screenWidth))
        }
        if onScreen {
            let next = index + 1
            if lookahead.isReady(next), !store.isRequested(next) {
                let layout = lookahead.mosaic(forCycle: next, counting: false).planned.layout
                store.request(cycle: next, widths: closeUpWidths(of: layout, screenWidth: screenWidth))
            }
        } else {
            store.wait(for: index)
        }

        let latched = store.latch(cycle: index)
        let misses = earlierCloseUpMisses + store.misses
        let bytes = store.residentBytes
        statisticsBox.update {
            $0.closeUpMisses = misses
            $0.closeUpBytes = bytes
        }
        return latched
    }

    /// The photographs of a cycle that get bigger on screen than an atlas slice,
    /// within `closeUpRing` cells of the anchor, each with the width in pixels
    /// it reaches at its largest.
    private func closeUpWidths(of layout: MosaicLayout, screenWidth: Int) -> [PhotoID: Int] {
        let geometry = layout.geometry
        let anchor = layout.anchor
        let path = CameraPath(
            curve: ZoomCurve(zoomFactor: Double(layout.rows)),
            anchorCenter: geometry.center(of: anchor)
        )
        let rows = max(0, anchor.row - closeUpRing)...min(layout.rows - 1, anchor.row + closeUpRing)
        let columns = max(0, anchor.column - closeUpRing)...min(layout.rows - 1, anchor.column + closeUpRing)

        var widths: [PhotoID: Int] = [:]
        for row in rows {
            for column in columns {
                let cell = GridCell(column: column, row: row)
                let largest = path.largestOnScreenWidth(of: geometry.rect(of: cell))
                let pixels = Int((largest * Double(screenWidth)).rounded(.up))
                guard pixels > tilePixelWidth else { continue }
                let photo = layout[cell].photo
                widths[photo] = max(widths[photo] ?? 0, pixels)
            }
        }
        return widths
    }

    private func mosaic(forCycle index: Int, onScreen: Bool) -> Lookahead.Built {
        let built = lookahead.mosaic(forCycle: index, counting: onScreen)
        if let error = built.error {
            statisticsBox.update { $0.lastError = error }
        }
        return built
    }

    private func report(_ built: Lookahead.Built) {
        let stalls = lookahead.stalls
        statisticsBox.update {
            $0.subject = built.planned.layout.subject.rawValue
            $0.solve = built.planned.statistics
            $0.stalls = stalls
        }
    }
}
