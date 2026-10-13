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

    /// Every cell's delta E, row-major, `R × R`. The headline numbers say how
    /// good a mosaic is; this says *where* it is not, which is what separates
    /// "the corpus has no photograph of that colour" from "the spreading pushed
    /// a worse one in". The error map of the harness is drawn from it.
    public var cellDeltaE: [Double]

    /// How many cells each photograph of the pool holds, in pool order, zeros
    /// included. `maximumUses` is its tail and `distinctPhotos` its support;
    /// the whole distribution is what tells an even spread from a few
    /// photographs carrying a sky.
    public var photoUses: [Int]

    /// The anchor's cell, row-major; then the ring around it
    /// (`SolverOptions.ring`), anchor left out:
    /// how many cells, their root mean square delta E, and how many hold a
    /// photograph that is not sharp enough for it.
    public var anchorIndex = -1
    public var ringCells = 0
    public var ringRootMeanSquareDeltaE = 0.0
    public var ringNotSharp = 0

    public init(
        rootMeanSquareDeltaE: Double = 0,
        maximumDeltaE: Double = 0,
        distinctPhotos: Int = 0,
        maximumUses: Int = 0,
        anchorDeltaE: Double = 0,
        cellCount: Int = 0,
        cellDeltaE: [Double] = [],
        photoUses: [Int] = []
    ) {
        self.rootMeanSquareDeltaE = rootMeanSquareDeltaE
        self.maximumDeltaE = maximumDeltaE
        self.distinctPhotos = distinctPhotos
        self.maximumUses = maximumUses
        self.anchorDeltaE = anchorDeltaE
        self.cellCount = cellCount
        self.cellDeltaE = cellDeltaE
        self.photoUses = photoUses
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
