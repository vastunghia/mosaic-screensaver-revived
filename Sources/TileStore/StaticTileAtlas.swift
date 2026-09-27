import CoreGraphics
import Foundation
import Metal
import MosaicCore
import MosaicPhotos
import MosaicRender

public enum TileAtlasError: Error {
    case couldNotAllocateTexture
    case couldNotDrawImage
    case noCommandQueue
}

/// A tile atlas built once and never changed.
///
/// The debt milestone 2 left M6, in numbers: a mipmapped slice weighs about
/// `width × 9/16 × 4 × 1.33` bytes, 196 KB at 256 pixels; with `.managed`
/// storage there is a CPU copy as well, so on this machine's discrete AMD GPUs
/// the figure doubles. And a 2D texture array holds at most 2048 slices.
public final class StaticTileAtlas: TileAtlas {
    public let texture: MTLTexture
    private let slices: [PhotoID: Int]

    /// Decodes every photograph at `tileWidth` and uploads it.
    ///
    /// The decoding is spread over every core: it is almost all of the cost,
    /// and at 2048 photographs it was 9.3 s of startup on one thread.
    public convenience init(
        device: MTLDevice,
        queue: MTLCommandQueue,
        source: any PhotoSource,
        photos: [PhotoID],
        tileWidth: Int = 256
    ) throws {
        let size = (width: tileWidth, height: CanonicalAspect.height(forWidth: tileWidth))
        let bytesPerRow = size.width * 4
        let failures = FirstFailure()
        var images = [[UInt8]](repeating: [], count: photos.count)

        images.withUnsafeMutableBufferPointer { slots in
            let slots = UncheckedSlots(base: slots.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: photos.count) { index in
                do {
                    let image = try source.canonicalImage(for: photos[index], maxPixelWidth: tileWidth)
                    var pixels = [UInt8](repeating: 0, count: bytesPerRow * size.height)
                    try BGRABitmap.draw(image, into: &pixels, width: size.width, height: size.height)
                    slots.base[index] = pixels
                } catch {
                    failures.record(error)
                }
            }
        }
        if let error = failures.first { throw error }

        try self.init(device: device, queue: queue, photos: photos, pixels: images, tileSize: size)
    }

    /// - Parameter pixels: one BGRA bitmap per photograph, already at
    ///   `tileSize`, which is the atlas's one resolution.
    public init(
        device: MTLDevice,
        queue: MTLCommandQueue,
        photos: [PhotoID],
        pixels: [[UInt8]],
        tileSize: (width: Int, height: Int)
    ) throws {
        precondition(!photos.isEmpty, "an atlas needs at least one tile")
        precondition(photos.count == pixels.count, "one bitmap per photograph")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: tileSize.width,
            height: tileSize.height,
            mipmapped: true
        )
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = photos.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TileAtlasError.couldNotAllocateTexture
        }

        var slices: [PhotoID: Int] = [:]
        let bytesPerRow = tileSize.width * 4

        for (index, id) in photos.enumerated() {
            pixels[index].withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, tileSize.width, tileSize.height),
                    mipmapLevel: 0,
                    slice: index,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerRow * tileSize.height
                )
            }
            slices[id] = index
        }

        // The mip pyramid is not an optimisation here, it is what stops the
        // minified tiles from shimmering — and shimmering would be read as a
        // flaw in the movement rather than in the sampling. On an `_srgb`
        // format it averages in linear light, which was measured (PLAN.md).
        guard let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw TileAtlasError.noCommandQueue
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        self.texture = texture
        self.slices = slices
    }

    public func slice(for photo: PhotoID) -> Int? {
        slices[photo]
    }

    public var count: Int { slices.count }
}

/// Each concurrent iteration writes its own slot and no other, which is what
/// makes sharing the pointer safe.
private struct UncheckedSlots: @unchecked Sendable {
    let base: UnsafeMutablePointer<[UInt8]>
}

final class FirstFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if self.error == nil { self.error = error }
    }

    var first: Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}
