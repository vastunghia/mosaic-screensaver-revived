import CycleEngine
import Metal
import MosaicCore
import simd

public enum RendererError: Error {
    case metallibNotFound
    case missingShaderFunction(String)
    case couldNotAllocateBuffer
}

/// M7. Draws a FrameState, and knows nothing else.
///
/// It has no idea what a photograph is or what time it is, it does not own a
/// layer or a drawable, and it takes its MTLDevice from outside — a screen saver
/// instance has to be able to draw on the GPU that actually drives its display,
/// which is not necessarily the system default one.
public final class Renderer {
    /// How many frames the CPU may run ahead of the GPU. The host is expected to
    /// throttle itself to this.
    public static let inFlightFrameCount = 3

    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var instanceBuffers: [MTLBuffer?]
    private var instanceCapacity: Int = 0
    private var frameSlot = 0
    private var instances: [TileInstance] = []

    /// The real initialiser: the library comes from outside, so tests and the
    /// development harness can supply one compiled however they like.
    public init(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    ) throws {
        guard let vertexFunction = library.makeFunction(name: "tile_vertex") else {
            throw RendererError.missingShaderFunction("tile_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "tile_fragment") else {
            throw RendererError.missingShaderFunction("tile_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        // Premultiplied source-over: the fragment shader already multiplies the
        // colour by the alpha. This is what dissolves the previous mosaic into
        // the flat photograph underneath it.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.maxAnisotropy = 4

        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.couldNotAllocateBuffer
        }

        self.device = device
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.sampler = sampler
        self.instanceBuffers = Array(repeating: nil, count: Self.inFlightFrameCount)
    }

    /// Resolves default.metallib from the bundle the renderer's own code lives
    /// in — the app bundle or the .saver, without either of them having to say
    /// which. This is the path spike 1 verified inside legacyScreenSaver.
    public convenience init(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    ) throws {
        let bundle = Bundle(for: Renderer.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            throw RendererError.metallibNotFound
        }
        try self.init(device: device, library: library, colorPixelFormat: colorPixelFormat)
    }

    /// The clear colour behind everything. Black, because any tile the atlas
    /// cannot supply should read as absence rather than as a colour choice.
    public static let clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    public func encode(_ frame: FrameState, atlas: TileAtlas, into encoder: MTLRenderCommandEncoder) {
        instances.removeAll(keepingCapacity: true)
        appendTiles(of: frame, using: atlas)
        guard !instances.isEmpty else { return }

        guard let buffer = buffer(for: instances.count) else { return }
        buffer.contents()
            .withMemoryRebound(to: TileInstance.self, capacity: instances.count) { destination in
                destination.update(from: instances, count: instances.count)
            }

        var camera = CameraUniforms(
            center: SIMD2<Float>(Float(frame.camera.center.x), Float(frame.camera.center.y)),
            halfSpan: Float(frame.camera.visibleWidth / 2)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: instances.count
        )
    }

    /// Builds the instance list for one frame: the current mosaic, then the
    /// previous one on top of it while it is still a grid.
    ///
    /// The previous mosaic's flat photograph needs no draw of its own. It is
    /// already there: the tile the current mosaic puts in its anchor cell *is*
    /// that photograph (SPEC § 5, step 4). So the crossfade is one layer fading
    /// out to reveal what was underneath all along.
    private func appendTiles(of frame: FrameState, using atlas: TileAtlas) {
        let visible = frame.camera.visibleRect
        let geometry = frame.current.geometry

        geometry.cells(intersecting: visible).forEach { cell in
            guard let slice = atlas.slice(for: frame.current[cell].photo) else { return }
            append(rect: geometry.rect(of: cell), slice: slice, alpha: 1)
        }

        guard let previous = frame.previous, previous.mosaicAlpha > 0.001 else { return }

        // The previous mosaic lives inside one cell of the current one, so its
        // own unit square maps onto that cell's rectangle.
        let host = previous.rect
        let inner = NormalizedRect(
            x: (visible.minX - host.minX) / host.width,
            y: (visible.minY - host.minY) / host.height,
            width: visible.width / host.width,
            height: visible.height / host.height
        )
        let innerGeometry = previous.layout.geometry
        let alpha = Float(previous.mosaicAlpha)

        innerGeometry.cells(intersecting: inner).forEach { cell in
            guard let slice = atlas.slice(for: previous.layout[cell].photo) else { return }
            let local = innerGeometry.rect(of: cell)
            let mapped = NormalizedRect(
                x: host.minX + local.minX * host.width,
                y: host.minY + local.minY * host.height,
                width: local.width * host.width,
                height: local.height * host.height
            )
            append(rect: mapped, slice: slice, alpha: alpha)
        }
    }

    private func append(rect: NormalizedRect, slice: Int, alpha: Float) {
        instances.append(
            TileInstance(
                origin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
                size: SIMD2<Float>(Float(rect.width), Float(rect.height)),
                slice: Float(slice),
                alpha: alpha
            )
        )
    }

    private func buffer(for count: Int) -> MTLBuffer? {
        frameSlot = (frameSlot + 1) % Self.inFlightFrameCount

        if count > instanceCapacity {
            // Grow generously: R can be changed from the harness while the
            // effect runs, and reallocating mid-cycle should not become routine.
            instanceCapacity = max(count * 2, 1024)
            instanceBuffers = Array(repeating: nil, count: Self.inFlightFrameCount)
        }

        if let existing = instanceBuffers[frameSlot] {
            return existing
        }

        let made = device.makeBuffer(
            length: instanceCapacity * MemoryLayout<TileInstance>.stride,
            options: .storageModeShared
        )
        instanceBuffers[frameSlot] = made
        return made
    }
}
