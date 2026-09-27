import Foundation
import Metal
import MosaicCore
import MosaicPhotos
import MosaicRender
import TileStore

/// Everything the engine holds that belongs to one `MTLDevice`, so that it can
/// be thrown away and made again on another one in a single step.
///
/// An eGPU can be unplugged while the effect runs, and it takes its device with
/// it. Nothing here survives that; everything that does — the mosaics, the
/// sequence of subjects, the time — lives on the CPU side of the engine and is
/// not in this object.
final class GPUResources {
    /// What it takes to make the resources again, on any device.
    struct Recipe: @unchecked Sendable {
        let source: any PhotoSource
        let photos: [PhotoID]
        let tileWidth: Int
        let closeUpSource: (any PhotoSource)?
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderer: Renderer
    let atlas: TileAtlas
    let closeUps: CloseUpStore?

    /// Per device, because frames in flight on a device that has gone may never
    /// complete, and a semaphore shared with the next device would then block it
    /// for ever.
    let inFlight = DispatchSemaphore(value: Renderer.inFlightFrameCount)

    /// - Parameter library: compiled for `device`. Nil resolves default.metallib
    ///   from the bundle the renderer's code lives in, which is the only option
    ///   on a rebuild: a library belongs to the device it was made for.
    init(device: MTLDevice, library: MTLLibrary?, recipe: Recipe) throws {
        guard let queue = device.makeCommandQueue() else {
            throw MosaicEngineError.noCommandQueue
        }
        self.device = device
        self.queue = queue
        self.renderer = try library.map { try Renderer(device: device, library: $0) }
            ?? Renderer(device: device)
        // Built up front, and the host waits for it. Decoding runs on every
        // core; the atlas is still one array, whole and blocking, and making it
        // incremental is left for when a pool outgrows 2048 slices.
        self.atlas = try StaticTileAtlas(
            device: device,
            queue: queue,
            source: recipe.source,
            photos: recipe.photos,
            tileWidth: recipe.tileWidth
        )
        self.closeUps = try recipe.closeUpSource.map { try CloseUpStore(device: device, source: $0) }
    }

    /// A device still attached, other than `lost`: the system default if it
    /// qualifies, else a built-in one, else anything.
    static func survivingDevice(avoiding lost: MTLDevice?) -> MTLDevice? {
        let candidates = MTLCopyAllDevices().filter { $0.registryID != lost?.registryID }
        if let preferred = MTLCreateSystemDefaultDevice(),
           candidates.contains(where: { $0.registryID == preferred.registryID }) {
            return preferred
        }
        return candidates.first { !$0.isRemovable } ?? candidates.first
    }
}
