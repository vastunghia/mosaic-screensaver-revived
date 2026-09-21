import CoreGraphics
import Foundation
import Metal
import MosaicCore
import MosaicEngine
import MosaicPhotos
import MosaicSolver

/// One mosaic, held still, with its target photograph beside it and its numbers
/// underneath.
///
/// This is milestone 2's deliverable. The judgement it exists to support — are
/// these good tiles? — cannot be made at 60 fps, and cannot be made from memory
/// either: two settings have to be seen side by side, on the same photograph,
/// with something quantitative to argue against a first impression.
enum MosaicExporter {
    static func export(
        to file: URL,
        cycle: Int,
        width: Int,
        settings: MosaicSettings,
        device: MTLDevice,
        library: MTLLibrary,
        photos: PhotoSourceFactory.Resolved,
        planner: (any MosaicPlanner)?,
        tileWidth: Int
    ) throws {
        let height = CanonicalAspect.height(forWidth: width)
        let engine = try MosaicEngine(
            device: device,
            settings: settings,
            source: photos.source,
            planner: planner,
            library: library,
            tilePixelWidth: tileWidth
        )

        guard let texture = engine.makeOffscreenTexture(width: width, height: height) else {
            throw ExportError.couldNotAllocateTexture
        }

        let started = Date()
        let subject = engine.renderMosaic(cycle: cycle, into: texture)
        let elapsed = Date().timeIntervalSince(started)

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        try PNGWriter.write(pixels: pixels, width: width, height: height, to: file)

        // The target next to the mosaic. Judging a photomosaic against a
        // remembered photograph is judging the memory.
        let beside = file
            .deletingPathExtension()
            .appendingPathExtension("target.png")
        if let original = try? photos.source.canonicalImage(for: subject, maxPixelWidth: width) {
            try PNGWriter.write(image: original, to: beside)
        }

        print("mosaic of \(subject.rawValue)")
        print(String(format: "  %dx%d, cycle %d, solved in %.2f s", width, height, cycle, elapsed))
        print("  \(file.path)")
        print("  \(beside.path)")
        if let statistics = engine.statistics.solve {
            print(report(statistics))
        }
        if let error = engine.statistics.lastError {
            print("  WARNING: fell back to random tiles: \(error)")
        }
    }

    /// The six numbers. They are what turns "that one looks worse" into "that
    /// one is worse, by twelve per cent".
    static func report(_ statistics: SolveStatistics) -> String {
        [
            String(format: "  delta E   rms %.2f   worst %.2f", statistics.rootMeanSquareDeltaE, statistics.maximumDeltaE),
            String(format: "  tiles     %d distinct of %d cells, most-used %d times",
                   statistics.distinctPhotos, statistics.cellCount, statistics.maximumUses),
            String(format: "  anchor    delta E %.2f (what forcing B into its cell cost)", statistics.anchorDeltaE),
        ].joined(separator: "\n")
    }
}
