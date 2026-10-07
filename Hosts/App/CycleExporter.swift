import CoreGraphics
import Foundation
import ImageIO
import Metal
import MosaicCore
import MosaicEngine
import MosaicPhotos
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
        cycles: Int = 1,
        closing: Bool = false,
        device: MTLDevice,
        library: MTLLibrary,
        source: any PhotoSource,
        planner: (any MosaicPlanner)?,
        tileWidth: Int,
        seed: UInt64,
        closeUpSource: (any PhotoSource)?,
        closeUpOptions: CloseUpOptions
    ) throws {
        let height = CanonicalAspect.height(forWidth: width)
        let engine = try MosaicEngine(
            device: device,
            settings: settings,
            source: source,
            planner: planner,
            library: library,
            seed: seed,
            tilePixelWidth: tileWidth,
            closeUpSource: closeUpSource,
            closeUpOptions: closeUpOptions
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let texture = engine.makeOffscreenTexture(width: width, height: height) else {
            throw ExportError.couldNotAllocateTexture
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        print("exporting \(frames * cycles) frames of \(width)x\(height) to \(directory.path)\(cycles > 1 ? ", \(cycles) cycles" : "")")
        print("GPU: \(engine.deviceName)")

        func write(at time: TimeInterval, to name: String) throws {
            engine.renderFrame(at: time, into: texture)
            pixels.withUnsafeMutableBytes { raw in
                texture.getBytes(
                    raw.baseAddress!,
                    bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }
            try PNGWriter.write(pixels: pixels, width: width, height: height, to: directory.appendingPathComponent(name))
        }

        // The last frame of a cycle is the first of the next one, so each
        // cycle stops just short of it: exporting both would look like a
        // duplicate rather than like continuity. Numbered on across cycles.
        for cycle in 0..<cycles {
            for frame in 0..<frames {
                let u = Double(frame) / Double(frames)
                let time = (Double(startCycle + cycle) + u) * settings.cycleDuration
                try write(at: time, to: String(format: "%04d.png", cycle * frames + frame))
            }
        }

        // The frame the sequence would go on to, which a loop has to match
        // with its first, byte for byte.
        if closing {
            try write(at: Double(startCycle + cycles) * settings.cycleDuration, to: "closing.png")
        }

        print("done: \(directory.path)")
    }

}
