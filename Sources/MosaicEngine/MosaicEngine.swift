import CoreGraphics
import CycleEngine
import Metal
import MosaicCore
import MosaicPhotos
import MosaicRender
import QuartzCore

public enum MosaicEngineError: Error {
    case noCommandQueue
    case emptyPhotoSource
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

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: Renderer
    private let atlas: TileAtlas
    private let pool: [PhotoID]
    private let builder: LayoutBuilder
    private let seed: UInt64

    private var cycle: CycleEngine
    private var layouts: [Int: MosaicLayout] = [:]
    private var subjects: [Int: PhotoID] = [:]

    private var layer: CAMetalLayer?
    private let inFlight: DispatchSemaphore

    /// - Parameter renderer: normally left to the engine, which resolves
    ///   default.metallib from its own bundle. The harness passes one in when it
    ///   wants shaders compiled some other way.
    public init(
        device: MTLDevice,
        settings: MosaicSettings = MosaicSettings(),
        source: PhotoSource = SyntheticPhotoSource(),
        builder: LayoutBuilder = RandomLayoutBuilder(),
        renderer: Renderer? = nil,
        seed: UInt64 = 0x4D05_A1C0,
        tilePixelWidth: Int = 256
    ) throws {
        guard let queue = device.makeCommandQueue() else {
            throw MosaicEngineError.noCommandQueue
        }

        let descriptors = try source.photos()
        guard !descriptors.isEmpty else {
            throw MosaicEngineError.emptyPhotoSource
        }

        // Milestone 1 builds the whole atlas up front and blocks while it does.
        // That is only acceptable because the photographs are synthetic and
        // there are a few hundred of them; M6 is where this becomes incremental,
        // asynchronous and bounded by a memory budget.
        let images = try descriptors.map {
            ($0.id, try source.image(for: $0.id, maxPixelWidth: tilePixelWidth))
        }

        self.device = device
        self.queue = queue
        self.settings = settings
        self.cycle = CycleEngine(settings: settings)
        self.builder = builder
        self.seed = seed
        self.pool = descriptors.map(\.id)
        self.renderer = try renderer ?? Renderer(device: device)
        self.atlas = try StaticTileAtlas(
            device: device,
            queue: queue,
            images: images,
            tileSize: (tilePixelWidth, Int((Double(tilePixelWidth) * 9 / 16).rounded()))
        )
        self.inFlight = DispatchSemaphore(value: Renderer.inFlightFrameCount)
    }

    // MARK: - Host API

    public func attach(to layer: CAMetalLayer, size: CGSize) {
        layer.device = device
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
        self.settings = settings
        self.cycle = CycleEngine(settings: settings)
        // The layouts depend on R, so changing it invalidates them. Nothing else
        // does: the curve and the crossfade are read fresh every frame.
        layouts.removeAll(keepingCapacity: true)
    }

    /// Draws the frame for an absolute time. There is no internal clock: the
    /// host owns time, which is what lets the harness scrub it.
    public func advance(to time: TimeInterval) {
        guard let layer, let drawable = layer.nextDrawable() else { return }

        let frame = frameState(at: time)

        inFlight.wait()
        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            renderer.encode(frame, atlas: atlas, into: encoder)
            encoder.endEncoding()
        }

        commands.present(drawable)
        commands.commit()
    }

    /// The same frame, drawn into a texture instead of onto a screen. This is
    /// what makes everything else verifiable: a cycle can be exported frame by
    /// frame and looked at cold.
    public func renderFrame(at time: TimeInterval, into texture: MTLTexture) {
        guard let commands = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.clearColor

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            renderer.encode(frameState(at: time), atlas: atlas, into: encoder)
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
        return device.makeTexture(descriptor: descriptor)
    }

    /// The MTLDevice actually in use, so measurements can be labelled with it.
    /// A Radeon Pro 560X and an RX 6800 are far too different for an unlabelled
    /// frame time to mean anything.
    public var deviceName: String { device.name }

    // MARK: - Lookahead

    private func frameState(at time: TimeInterval) -> FrameState {
        let index = cycle.position(at: time).index
        // SPEC § 2 wants the tiles to look as though they had always been there,
        // so nothing may be built while it is on screen. Milestone 1 builds them
        // one cycle early and synchronously; the background work is M8's job
        // proper, in milestone 3.
        for needed in cycle.cyclesNeeded(at: time) {
            _ = layout(forCycle: needed)
        }
        return cycle.frame(
            at: time,
            current: layout(forCycle: index),
            previous: index > 0 ? layout(forCycle: index - 1) : nil
        )
    }

    private func subject(ofCycle index: Int) -> PhotoID {
        if let known = subjects[index] { return known }
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9)
        let chosen = pool[Int(rng.next() % UInt64(pool.count))]
        subjects[index] = chosen
        return chosen
    }

    private func layout(forCycle index: Int) -> MosaicLayout {
        if let known = layouts[index] { return known }
        let built = builder.layout(
            rows: settings.rows,
            subject: subject(ofCycle: index),
            previousSubject: index > 0 ? subject(ofCycle: index - 1) : nil,
            pool: pool,
            seed: seed &+ UInt64(bitPattern: Int64(index)) &* 0x2545_F491
        )
        layouts[index] = built
        // Two live layers at a time (SPEC § 6), so nothing older than the
        // previous cycle is worth keeping.
        layouts = layouts.filter { $0.key >= index - 2 }
        layouts[index] = built
        return built
    }
}
