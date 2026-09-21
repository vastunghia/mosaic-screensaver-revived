import Foundation
import MosaicCore
import MosaicPhotos
import MosaicSolver

/// Command line options. Deliberately tiny: this is a development harness, and
/// anything worth keeping ends up in the preferences of the real app instead.
struct Options {
    var rows = 60
    var cycleDuration: Double = 25
    var crossfadeDuration: Double = 0.30

    /// How many photographs the mosaic may draw from. Also the size of the tile
    /// atlas, because the solver may pick any of them.
    var poolSize = 1024

    /// Where real photographs come from. Without it the harness runs on
    /// synthetic images, which is how milestone 1 judged the movement.
    var folder: URL?
    var indexDirectory: URL?
    var buildIndex = false

    var tileWidth = 256
    var exportMosaic: URL?
    var randomTiles = false
    var subject: String?

    // The quality knobs. They are options and not constants because milestone 2
    // exists to settle them by looking at exports.
    var detail = 1
    var spacing = 3
    var repeatPenalty: Double = 2
    var maximumUses: Int?
    var lightnessWeight: Double = 1
    var chromaWeight: Double = 1

    var exportDirectory: URL?
    var exportFrames = 240
    var exportWidth = 1280
    var exportCycle = 1
    var fullScreen = false

    /// Flags that were not understood. They used to be dropped in silence, and
    /// with this many options a mistyped `--foler` would hand back a synthetic
    /// mosaic and cost an evening of judging the wrong thing.
    var unknown: [String] = []

    var solverOptions: SolverOptions {
        SolverOptions(
            detail: detail,
            weights: LabWeights(lightness: lightnessWeight, chroma: chromaWeight),
            repetitionSpacing: spacing,
            repetitionPenalty: repeatPenalty,
            maximumUses: maximumUses
        )
    }

    var settings: MosaicSettings {
        MosaicSettings(
            rows: rows,
            cycleDuration: cycleDuration,
            crossfadeDuration: crossfadeDuration
        )
    }

    /// The index directory, which the app owns.
    ///
    /// `~/Library/Application Support/Mosaic/` is the path contract of M11: the
    /// app writes there because it is its own home, and the saver reads from
    /// there because spike 2 showed its sandbox allows reading outside the
    /// container but not writing.
    var resolvedIndexDirectory: URL {
        if let indexDirectory { return indexDirectory }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let home = support.first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return home.appendingPathComponent("Mosaic/index", isDirectory: true)
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0

        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        func path() -> URL? {
            next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--rows": options.rows = next().flatMap(Int.init) ?? options.rows
            case "--duration": options.cycleDuration = next().flatMap(Double.init) ?? options.cycleDuration
            case "--crossfade": options.crossfadeDuration = next().flatMap(Double.init) ?? options.crossfadeDuration
            case "--pool": options.poolSize = next().flatMap(Int.init) ?? options.poolSize
            case "--folder": options.folder = path()
            case "--index": options.indexDirectory = path()
            case "--build-index": options.buildIndex = true
            case "--tile-width": options.tileWidth = next().flatMap(Int.init) ?? options.tileWidth
            case "--export-mosaic": options.exportMosaic = path()
            case "--subject": options.subject = next()
            case "--random-tiles": options.randomTiles = true
            case "--k": options.detail = next().flatMap(Int.init) ?? options.detail
            case "--spacing": options.spacing = next().flatMap(Int.init) ?? options.spacing
            case "--repeat-penalty": options.repeatPenalty = next().flatMap(Double.init) ?? options.repeatPenalty
            case "--max-uses": options.maximumUses = next().flatMap(Int.init)
            case "--lightness-weight": options.lightnessWeight = next().flatMap(Double.init) ?? options.lightnessWeight
            case "--chroma-weight": options.chromaWeight = next().flatMap(Double.init) ?? options.chromaWeight
            case "--export-cycle": options.exportDirectory = path()
            case "--frames": options.exportFrames = next().flatMap(Int.init) ?? options.exportFrames
            case "--width": options.exportWidth = next().flatMap(Int.init) ?? options.exportWidth
            case "--cycle": options.exportCycle = next().flatMap(Int.init) ?? options.exportCycle
            case "--full-screen": options.fullScreen = true
            default:
                if argument.hasPrefix("-") { options.unknown.append(argument) }
            }
            index += 1
        }

        return options
    }

    /// Printed at startup, because an option that was understood differently
    /// from how it was meant is invisible otherwise.
    func banner(sourceDescription: String) -> String {
        var lines = ["mosaic: \(sourceDescription)"]
        lines.append(String(
            format: "  R = %d · T = %.0f s · crossfade %.2f u · tiles %d px",
            rows, cycleDuration, crossfadeDuration, tileWidth
        ))
        if folder != nil {
            lines.append(String(
                format: "  k = %d · spacing %d · penalty %.1f · max uses %@ · weights L %.2f C %.2f",
                detail, spacing, repeatPenalty,
                maximumUses.map(String.init) ?? "derived",
                lightnessWeight, chromaWeight
            ))
            lines.append("  index: \(resolvedIndexDirectory.path)")
        }
        if randomTiles {
            lines.append("  tiles chosen at RANDOM (--random-tiles)")
        }
        for flag in unknown {
            lines.append("  WARNING: ignoring unknown option \(flag)")
        }
        return lines.joined(separator: "\n")
    }
}
