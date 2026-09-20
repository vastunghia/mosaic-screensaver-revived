import CoreGraphics
import Foundation
import ImageIO
import Metal
import MosaicCore
import MosaicEngine
import UniformTypeIdentifiers

/// Renders a whole cycle offscreen, one PNG per frame.
///
/// PLAN.md calls this the most useful verification tool of the project, and the
/// reason is that the things this effect can get wrong — a seam at the join, a
/// drift that should not be there, a tile popping into place — are all things
/// the eye misses at 60 fps and catches immediately on a still, or on two stills
/// side by side.
enum CycleExporter {
    static func export(
        to directory: URL,
        frames: Int,
        width: Int,
        settings: MosaicSettings,
        startCycle: Int,
        device: MTLDevice,
        library: MTLLibrary,
        poolSize: Int
    ) throws {
        let height = Int((Double(width) * 9 / 16).rounded())
        let engine = try MosaicEngine(
            device: device,
            settings: settings,
            source: SyntheticPhotoSourceFactory.make(count: poolSize),
            library: library
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let texture = engine.makeOffscreenTexture(width: width, height: height) else {
            throw ExportError.couldNotAllocateTexture
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        print("esporto \(frames) frame \(width)x\(height) in \(directory.path)")
        print("GPU: \(engine.deviceName)")

        for frame in 0..<frames {
            // The last frame of a cycle is the first of the next one, so the
            // sequence stops just short of it: exporting both would look like a
            // duplicate rather than like continuity.
            let u = Double(frame) / Double(frames)
            let time = (Double(startCycle) + u) * settings.cycleDuration
            engine.renderFrame(at: time, into: texture)

            pixels.withUnsafeMutableBytes { raw in
                texture.getBytes(
                    raw.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }

            let url = directory.appendingPathComponent(String(format: "%04d.png", frame))
            try write(pixels: pixels, width: width, height: height, to: url)
        }

        print("fatto: \(directory.path)")
    }

    private static func write(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
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
}
