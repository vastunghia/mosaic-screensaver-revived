import CoreGraphics
import Foundation
import Metal
import MosaicCore
import MosaicPhotos

/// Photographs at the size they reach on screen, for the few tiles that get
/// bigger than an atlas slice.
///
/// At the start of a cycle one tile fills the screen and its neighbours come on
/// screen almost as big: on a 4096-pixel display at R = 60 they are wider than
/// a 256-pixel slice for the first 60 % of the cycle. So each cycle has a small
/// set of close-ups — the anchor and, optionally, a ring around it — and this
/// store has them decoded and uploaded before the cycle begins.
///
/// **Nothing changes resolution on screen.** SPEC § 2 allows one transition
/// and it is not this one: a tile turning sharp mid-zoom would be a visible
/// event. So the set a cycle uses is fixed the first time the cycle is drawn
/// (`latch`), and a close-up that was not ready by then is not used for that
/// cycle at all: the tile stays the atlas slice throughout. It is counted.
///
/// The pixels come from a `PhotoSource` and this store does not know which. In
/// the app it is the originals; given the index alone it is exactly what the
/// .saver would see. Either way they are the canonical crop, so when the crop
/// learns about faces this store needs no change.
public final class CloseUpStore: @unchecked Sendable {
    public let device: MTLDevice
    private let source: any PhotoSource
    private let queue: MTLCommandQueue
    private let work = DispatchQueue(label: "mosaic.close-ups", qos: .utility)

    private let lock = NSLock()
    private var requested: [Int: DispatchGroup] = [:]
    private var loaded: [Int: [PhotoID: MTLTexture]] = [:]
    private var latched: [Int: [PhotoID: MTLTexture]] = [:]
    private var wanted: [Int: Int] = [:]
    private var missCount = 0
    private var failureCount = 0

    public init(device: MTLDevice, source: any PhotoSource) throws {
        guard let queue = device.makeCommandQueue() else {
            throw TileAtlasError.noCommandQueue
        }
        self.device = device
        self.source = source
        self.queue = queue
    }

    /// Starts decoding and uploading the close-ups of `cycle`, each photograph
    /// at most `widths[photo]` pixels across. A cycle is requested once; later
    /// calls — with a new screen size, say — are ignored, because its set may
    /// already be on screen.
    public func request(cycle: Int, widths: [PhotoID: Int]) {
        lock.lock()
        guard requested[cycle] == nil else {
            lock.unlock()
            return
        }
        let group = DispatchGroup()
        requested[cycle] = group
        wanted[cycle] = widths.count
        lock.unlock()

        // Sorted, so the order of the work does not depend on a dictionary's.
        let jobs = widths.sorted { $0.key.rawValue < $1.key.rawValue }
        group.enter()
        work.async { [self] in
            defer { group.leave() }
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                let (photo, width) = jobs[index]
                guard isStillWanted(cycle) else { return }
                do {
                    let texture = try upload(photo, width: width)
                    lock.lock()
                    if requested[cycle] != nil { loaded[cycle, default: [:]][photo] = texture }
                    lock.unlock()
                } catch {
                    lock.lock()
                    failureCount += 1
                    lock.unlock()
                }
            }
        }
    }

    public func isRequested(_ cycle: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requested[cycle] != nil
    }

    /// Whether every close-up asked for `cycle` has been dealt with, loaded or
    /// failed. False for a cycle never asked for.
    public func isComplete(_ cycle: Int) -> Bool {
        lock.lock()
        let group = requested[cycle]
        lock.unlock()
        return group?.wait(timeout: .now()) == .success
    }

    /// The close-ups `cycle` draws with, fixed the first time it is asked.
    public func latch(cycle: Int) -> [PhotoID: MTLTexture] {
        lock.lock(); defer { lock.unlock() }
        if let fixed = latched[cycle] { return fixed }
        let ready = loaded[cycle] ?? [:]
        latched[cycle] = ready
        missCount += max(0, (wanted[cycle] ?? 0) - ready.count)
        return ready
    }

    /// Blocks until the close-ups of `cycle` are all there, for offscreen
    /// rendering, where waiting is right and a miss would make an export
    /// depend on how busy the machine was.
    public func wait(for cycle: Int) {
        lock.lock()
        let group = requested[cycle]
        lock.unlock()
        group?.wait()
    }

    /// Only the cycle on screen draws close-ups — the previous one is a grid of
    /// small tiles by then — so anything older is dropped.
    public func evict(before cycle: Int) {
        lock.lock(); defer { lock.unlock() }
        for key in requested.keys where key < cycle {
            requested[key] = nil
            loaded[key] = nil
            latched[key] = nil
            wanted[key] = nil
        }
    }

    /// Close-ups that were asked for and not ready when their cycle began.
    public var misses: Int {
        lock.lock(); defer { lock.unlock() }
        return missCount
    }

    /// Close-ups that could not be decoded at all. Their tiles stay the atlas's.
    public var failures: Int {
        lock.lock(); defer { lock.unlock() }
        return failureCount
    }

    /// GPU memory held, mip pyramids included.
    public var residentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return loaded.values.reduce(0) { sum, textures in
            sum + textures.values.reduce(0) { $0 + $1.allocatedSize }
        }
    }

    private func isStillWanted(_ cycle: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requested[cycle] != nil
    }

    private func upload(_ photo: PhotoID, width: Int) throws -> MTLTexture {
        let image = try source.canonicalImage(for: photo, maxPixelWidth: width)
        // The source may give back less than was asked for — an original
        // smaller than the screen, or a thumbnail — and then that is the size.
        let size = (width: image.width, height: CanonicalAspect.height(forWidth: image.width))
        let bytesPerRow = size.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        try BGRABitmap.draw(image, into: &pixels, width: size.width, height: size.height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size.width,
            height: size.height,
            mipmapped: true
        )
        descriptor.usage = .shaderRead
        // Private: the GPU's own copy and no other. A managed texture of a
        // screenful would keep a second one in system memory for nothing.
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = pixels.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw TileAtlasError.couldNotAllocateTexture
        }

        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * size.height,
            sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        // A close-up shrinks from a screenful to one cell over the cycle, so it
        // needs its pyramid as much as the atlas does. Linear-light averaging on
        // `_srgb`, as measured for the atlas.
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return texture
    }
}
