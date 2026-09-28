import Foundation
import MosaicCore
import MosaicEngine
import MosaicPhotos
import MosaicSolver
import PhotoIndex

/// Command line options. Deliberately tiny: this is a development harness, and
/// anything worth keeping ends up in the preferences of the real app instead.
struct Options {
    var rows = 90
    var cycleDuration: Double = 25
    var crossfadeDuration: Double = 0.20

    /// How many photographs the mosaic may draw from. Also the size of the tile
    /// atlas, because the solver may pick any of them.
    ///
    /// The atlas ceiling, and not less: at 1024 a 2048-photograph corpus was
    /// solved from half of itself, and the full one was better on all three
    /// counts at once — delta E, distinct photographs, most uses.
    var poolSize = 2048

    /// Where real photographs come from. Without it the harness runs on
    /// synthetic images, which is how milestone 1 judged the movement.
    var folder: URL?
    var indexDirectory: URL?
    var buildIndex = false

    /// The Photos library instead of a folder, optionally narrowed to albums
    /// by title (SPEC § 5: no albums is the whole library). The app must be
    /// launched as an app — `open Mosaic.app --args …` — or TCC hands the grant
    /// to the terminal instead.
    var photosLibrary = false
    var albums: [String] = []
    /// The same, by identifier: what the app's preferences hold, since a title
    /// can be shared or renamed.
    var albumIdentifiers: [String] = []
    /// Download photographs kept only in iCloud (SPEC § 5, off by default).
    var allowsDownloads = false

    /// Which photographs of the library get indexed (SPEC § 5): spread over
    /// time, chosen by looking at the `subset` specimen; the size is the pool's
    /// ceiling. The seed is fixed, not per launch: a subset that changed every
    /// session would be indexed again every session.
    var subsetRule = SubsetRule.uniformInTime
    var subsetSize = 2048
    var subsetSeed: UInt64 = 0x5B5E_7000

    /// Checks the canonical-crop postcondition on this many photographs of the
    /// source and times it, instead of running anything.
    var verifyCanonical: Int?

    /// Writes the source's photographs — after the subset rule — with their
    /// dates to a CSV, instead of running anything.
    var listPhotos: URL?

    /// Whether the photographs are real, which is when there is an index, a
    /// solver and something to say about them.
    var usesRealPhotos: Bool { folder != nil || photosLibrary }

    /// The shape of the index. Not preferences: an index is built for one of
    /// each, and these exist so an experiment can build a second index beside
    /// the real one (with `--index`) instead of replacing it.
    var thumbnailWidth = PhotoIndexBuilder.defaultThumbnailWidth
    var signatureSide = PhotoIndexBuilder.defaultSignatureSide

    var tileWidth = 256

    /// Where the tiles that outgrow an atlas slice get their pixels: the
    /// originals, the index's thumbnails (exactly what the .saver has today),
    /// or nowhere, which draws everything from the atlas.
    enum CloseUps: String {
        case originals, thumbnails, off
    }
    var closeUps = CloseUps.originals
    /// Ring radius and the widths of anchor and ring. `--close-up-anchor-width 0`
    /// or `--close-up-ring-width 0` lifts a cap: as wide as the tile gets.
    var closeUpOptions = CloseUpOptions.standard
    var exportMosaic: URL?
    var randomTiles = false
    var subject: String?

    // The quality knobs. They are options and not constants because milestone 2
    // exists to settle them by looking at exports.
    var detail = SolverOptions.standard.detail
    var spacing = SolverOptions.standard.repetitionSpacing
    var repeatPenalty: Double = 1
    var maximumUses: Int?
    /// `--tolerance none` goes back to the penalty.
    var tolerance: Double? = SolverOptions.standard.tolerance
    var subjectCandidates = SolvedMosaicPlanner.defaultSubjectCandidates
    var lightnessWeight: Double = 1
    var chromaWeight: Double = 1

    /// Many subjects, each solved several ways, and a page to compare them on.
    /// The columns are the penalties and then the tolerances.
    var exportBatch: URL?
    var batchSubjects = 20
    var batchPenalties: [Double] = [0.5, 1, 2]
    var batchTolerances: [Double] = []

    /// What every random choice follows: which photographs make the pool,
    /// the order of the deck, where each anchor goes. A new one per launch, so
    /// no two sessions show the same sequence; a fixed one for anything
    /// exported, so a specimen regenerates byte for byte. `--seed` sets it
    /// either way, and the banner prints it, so a session worth seeing again
    /// can be.
    var seed = Options.reproducibleSeed
    var seedIsPerLaunch = false
    private var seedGiven = false
    static let reproducibleSeed: UInt64 = 0x4D05_A1C0

    var exportDirectory: URL?
    var exportFrames = 240
    var exportWidth = 1280
    var exportCycle = 1
    var fullScreen = false

    /// Rebuilds every GPU resource every so many seconds: the path an unplugged
    /// eGPU takes, exercised over and over without unplugging anything.
    var rebuildEvery: Double?

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
            maximumUses: maximumUses,
            tolerance: tolerance
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
            // The harness with nothing else changed: without any flag the app
            // opens its own window instead (see main.swift).
            case "--harness": break
            case "--photos-library": options.photosLibrary = true
            case "--album": if let title = next() { options.albums.append(title) }
            case "--icloud": options.allowsDownloads = true
            case "--subset":
                let value = next()
                if let rule = value.flatMap(SubsetRule.init(rawValue:)) {
                    options.subsetRule = rule
                } else {
                    options.unknown.append("--subset \(value ?? "") (recent, random or uniformInTime)")
                }
            case "--subset-size": options.subsetSize = next().flatMap(Int.init) ?? options.subsetSize
            case "--subset-seed": options.subsetSeed = next().flatMap(UInt64.init) ?? options.subsetSeed
            case "--verify-canonical": options.verifyCanonical = next().flatMap(Int.init)
            case "--list-photos": options.listPhotos = path()
            case "--thumbnail-width": options.thumbnailWidth = next().flatMap(Int.init) ?? options.thumbnailWidth
            case "--signature-side": options.signatureSide = next().flatMap(Int.init) ?? options.signatureSide
            case "--tile-width": options.tileWidth = next().flatMap(Int.init) ?? options.tileWidth
            case "--close-ups":
                let value = next()
                if let mode = value.flatMap(CloseUps.init(rawValue:)) {
                    options.closeUps = mode
                } else {
                    options.unknown.append("--close-ups \(value ?? "")")
                }
            case "--close-up-anchor-width":
                if let width = next().flatMap(Int.init) {
                    options.closeUpOptions.anchorWidth = width > 0 ? width : nil
                }
            case "--close-up-ring-width":
                if let width = next().flatMap(Int.init) {
                    options.closeUpOptions.ringWidth = width > 0 ? width : nil
                }
            case "--close-up-ring":
                options.closeUpOptions.ring = max(0, next().flatMap(Int.init) ?? options.closeUpOptions.ring)
            case "--export-mosaic": options.exportMosaic = path()
            case "--subject": options.subject = next()
            case "--random-tiles": options.randomTiles = true
            case "--k": options.detail = next().flatMap(Int.init) ?? options.detail
            case "--spacing": options.spacing = next().flatMap(Int.init) ?? options.spacing
            case "--repeat-penalty": options.repeatPenalty = next().flatMap(Double.init) ?? options.repeatPenalty
            case "--max-uses": options.maximumUses = next().flatMap(Int.init)
            case "--lightness-weight": options.lightnessWeight = next().flatMap(Double.init) ?? options.lightnessWeight
            case "--chroma-weight": options.chromaWeight = next().flatMap(Double.init) ?? options.chromaWeight
            case "--export-batch": options.exportBatch = path()
            case "--subjects": options.batchSubjects = next().flatMap(Int.init) ?? options.batchSubjects
            case "--seed":
                if let value = next().flatMap({ UInt64($0) ?? UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }) {
                    options.seed = value
                    options.seedGiven = true
                }
            case "--candidates": options.subjectCandidates = max(1, next().flatMap(Int.init) ?? options.subjectCandidates)
            case "--tolerance":
                let value = next()
                options.tolerance = value == "none" ? nil : value.flatMap(Double.init) ?? options.tolerance
            case "--penalties":
                // An empty list is allowed, for a batch of tolerances alone.
                options.batchPenalties = next()?.split(separator: ",").compactMap { Double($0) } ?? []
            case "--tolerances":
                options.batchTolerances = next()?.split(separator: ",").compactMap { Double($0) } ?? []
            case "--export-cycle": options.exportDirectory = path()
            case "--frames": options.exportFrames = next().flatMap(Int.init) ?? options.exportFrames
            case "--width": options.exportWidth = next().flatMap(Int.init) ?? options.exportWidth
            case "--cycle": options.exportCycle = next().flatMap(Int.init) ?? options.exportCycle
            case "--full-screen": options.fullScreen = true
            case "--rebuild-every": options.rebuildEvery = next().flatMap(Double.init)
            default:
                if argument.hasPrefix("-") { options.unknown.append(argument) }
            }
            index += 1
        }

        let exporting = options.exportMosaic != nil || options.exportBatch != nil
            || options.exportDirectory != nil || options.buildIndex || options.verifyCanonical != nil
            || options.listPhotos != nil
        if !options.seedGiven && !exporting {
            options.seed = UInt64.random(in: .min ... .max)
            options.seedIsPerLaunch = true
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
        lines.append(
            closeUps == .off
                ? "  close-ups off: every tile from the atlas"
                : "  close-ups from the \(closeUps.rawValue), ring \(closeUpOptions.ring)"
                    + " · anchor at most \(closeUpOptions.anchorWidth.map { "\($0) px" } ?? "screen width")"
                    + " · ring at most \(closeUpOptions.ringWidth.map { "\($0) px" } ?? "screen width")"
        )
        if photosLibrary {
            lines.append(
                "  Photos library · "
                    + (albums.isEmpty ? "all of it" : "albums \(albums.joined(separator: ", "))")
                    + (allowsDownloads ? " · iCloud downloads on" : " · iCloud-only photographs skipped")
            )
            lines.append("  indexed subset: \(subsetRule.rawValue), \(subsetSize) photographs, seed \(subsetSeed)")
        }
        if usesRealPhotos {
            lines.append(String(
                format: "  k = %d · spacing %d · %@ · max uses %@ · weights L %.2f C %.2f",
                detail, spacing,
                tolerance.map { String(format: "tolerance %g (penalty ignored)", $0) }
                    ?? String(format: "penalty %.1f", repeatPenalty),
                maximumUses.map(String.init) ?? (tolerance == nil ? "derived" : "none"),
                lightnessWeight, chromaWeight
            ))
            lines.append("  subjects: shuffled deck, each chosen among \(subjectCandidates) for the last to fit in")
            lines.append(String(
                format: "  index: %@ · thumbnails %d px · signatures %d×%d",
                resolvedIndexDirectory.path, thumbnailWidth, signatureSide, signatureSide
            ))
        }
        if exportBatch != nil {
            lines.append(String(
                format: "  batch: %d subjects from cycle %d · penalties [%@] · tolerances [%@]",
                batchSubjects, exportCycle,
                batchPenalties.map { String(format: "%g", $0) }.joined(separator: ", "),
                batchTolerances.map { String(format: "%g", $0) }.joined(separator: ", ")
            ))
            lines.append("    --repeat-penalty and --tolerance are ignored; --max-uses holds for penalty columns only")
        }
        lines.append(String(
            format: "  seed %llu%@", seed,
            seedIsPerLaunch ? " (new each launch; --seed to see this session again)" : ""
        ))
        if randomTiles {
            lines.append("  tiles chosen at RANDOM (--random-tiles)")
        }
        for flag in unknown {
            lines.append("  WARNING: ignoring unknown option \(flag)")
        }
        return lines.joined(separator: "\n")
    }
}
