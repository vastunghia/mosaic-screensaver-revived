import CoreGraphics
import Metal
import MosaicCore

/// The tiles, as the GPU sees them: one texture array, one slice per photograph,
/// with a mip pyramid.
///
/// This is the little that milestone 1 needs of M6. Residency, memory budget and
/// asynchronous loading are not here, and the protocol exists so that they can
/// arrive later without the renderer noticing.
public protocol TileSliceMap {
    /// Where a photograph sits in the texture array, or nil if the atlas does
    /// not hold it.
    func slice(for photo: PhotoID) -> Int?
}

public protocol TileAtlas: AnyObject, TileSliceMap {
    var texture: MTLTexture { get }
}

public enum TileAtlasError: Error {
    case couldNotAllocateTexture
    case couldNotDrawImage
    case noCommandQueue
}

/// A tile atlas built once and never changed.
public final class StaticTileAtlas: TileAtlas {
    public let texture: MTLTexture
    private let slices: [PhotoID: Int]

    /// - Parameter images: one image per photograph. All of them are resampled
    ///   to `tileSize`, which is the atlas's one resolution.
    public init(
        device: MTLDevice,
        queue: MTLCommandQueue,
        images: [(PhotoID, CGImage)],
        tileSize: (width: Int, height: Int) = (256, 144)
    ) throws {
        precondition(!images.isEmpty, "an atlas needs at least one tile")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: tileSize.width,
            height: tileSize.height,
            mipmapped: true
        )
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = images.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TileAtlasError.couldNotAllocateTexture
        }

        var slices: [PhotoID: Int] = [:]
        let bytesPerRow = tileSize.width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * tileSize.height)

        for (index, (id, image)) in images.enumerated() {
            try Self.draw(image, into: &buffer, width: tileSize.width, height: tileSize.height)
            buffer.withUnsafeBytes { raw in
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
        // flaw in the movement rather than in the sampling.
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

    private static func draw(
        _ image: CGImage,
        into buffer: inout [UInt8],
        width: Int,
        height: Int
    ) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // BGRA, premultiplied first, little endian: the byte order of
        // MTLPixelFormat.bgra8Unorm_srgb.
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: info
            ) else {
                return false
            }
            // No flip, and it is worth saying why the obvious one is wrong. A
            // bitmap context's first row of memory is the top of the image, and
            // `draw` puts the CGImage's first row there. Metal's texture origin
            // is also top-left, and the shader maps a tile's top edge to v = 0,
            // so the chain is already consistent end to end. Flipping here —
            // which looks right, because the user-space origin is at the bottom
            // left — renders every tile upside down. Milestone 1 could not see
            // it: a mirrored synthetic blob is another synthetic blob.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        if !ok { throw TileAtlasError.couldNotDrawImage }
    }
}
