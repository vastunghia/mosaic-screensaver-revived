import MosaicCore

/// How good the mosaic turned out, in numbers.
///
/// Milestone 2's deliverable is a judgement, so instrumenting the judgement is
/// not overhead — it is the deliverable. Without these, comparing two settings
/// is comparing two memories of two pictures.
public struct SolveStatistics: Equatable, Sendable {
    /// Root mean square distance between each cell's colour and the colour of
    /// the tile put there. The headline number.
    public var rootMeanSquareDeltaE: Double

    /// The worst single cell.
    public var maximumDeltaE: Double

    /// How many different photographs the mosaic is made of.
    public var distinctPhotos: Int

    /// How many cells the most-used photograph holds.
    public var maximumUses: Int

    /// What forcing B into the anchor cell cost, in delta E. SPEC § 5 step 4
    /// picks the anchor to keep this small; this is the check that it did.
    public var anchorDeltaE: Double

    public var cellCount: Int

    public init(
        rootMeanSquareDeltaE: Double = 0,
        maximumDeltaE: Double = 0,
        distinctPhotos: Int = 0,
        maximumUses: Int = 0,
        anchorDeltaE: Double = 0,
        cellCount: Int = 0
    ) {
        self.rootMeanSquareDeltaE = rootMeanSquareDeltaE
        self.maximumDeltaE = maximumDeltaE
        self.distinctPhotos = distinctPhotos
        self.maximumUses = maximumUses
        self.anchorDeltaE = anchorDeltaE
        self.cellCount = cellCount
    }
}

public struct SolveResult: Sendable {
    public let layout: MosaicLayout
    public let statistics: SolveStatistics

    public init(layout: MosaicLayout, statistics: SolveStatistics) {
        self.layout = layout
        self.statistics = statistics
    }
}

public enum MosaicSolverError: Error, CustomStringConvertible {
    case emptyPool
    case detailMismatch(target: Int, options: Int)
    case signatureTooCoarse(photo: PhotoID, side: Int, needed: Int)
    case poolTooSmallForSpacing(pool: Int, needed: Int)

    public var description: String {
        switch self {
        case .emptyPool:
            return "a mosaic needs photographs to be made of"
        case .detailMismatch(let target, let options):
            return "the target was sampled at detail \(target) but the solver wants \(options)"
        case .signatureTooCoarse(let photo, let side, let needed):
            return "\(photo.rawValue) has a \(side)x\(side) signature, too coarse for detail \(needed)"
        case .poolTooSmallForSpacing(let pool, let needed):
            return "a spacing that forbids \(needed) neighbours needs more than \(pool) photographs"
        }
    }
}
