import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writing a PNG, in one place, because both exporters do it.
enum PNGWriter {
    static func write(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: info),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw ExportError.couldNotMakeImage
        }
        try write(image: image, to: url)
    }

    static func write(image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ExportError.couldNotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.couldNotWrite(url)
        }
    }
}

enum ExportError: Error, CustomStringConvertible {
    case couldNotAllocateTexture
    case couldNotMakeImage
    case couldNotWrite(URL)

    var description: String {
        switch self {
        case .couldNotAllocateTexture: return "could not allocate the offscreen texture"
        case .couldNotMakeImage: return "could not build the CGImage from the readback"
        case .couldNotWrite(let url): return "could not write \(url.path)"
        }
    }
}
