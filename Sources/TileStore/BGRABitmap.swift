import CoreGraphics

/// A CGImage drawn into the byte layout of `MTLPixelFormat.bgra8Unorm_srgb`.
enum BGRABitmap {
    static func draw(_ image: CGImage, into buffer: inout [UInt8], width: Int, height: Int) throws {
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
