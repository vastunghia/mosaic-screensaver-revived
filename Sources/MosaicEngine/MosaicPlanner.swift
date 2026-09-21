import Foundation
import MosaicCore
import MosaicSolver

/// Decides what each cycle shows.
///
/// This used to be a `LayoutBuilder` that was handed a pool of identifiers and
/// asked for a layout. The obvious way to give it colour was to hand it the
/// palette and the target's cell colours as well — which would have made the
/// engine responsible for decoding images and doing colour arithmetic, work that
/// belongs to M3 and M5, and would have grown the method to six parameters of
/// which three were derived from the other three.
///
/// So the pool went the other way instead. The planner owns its photographs; the
/// engine owns the succession of cycles and the cache of layouts. Choosing
/// *which* photographs become subjects is a question about photographs — it is
/// the open subset question of SPEC § 8.6 in disguise — and not one about
/// orchestration.
public protocol MosaicPlanner: Sendable {
    /// The photograph cycle `index` zooms out to reveal.
    func subject(ofCycle index: Int) -> PhotoID

    /// - Parameters:
    ///   - previousSubject: the photograph of the cycle before, which has to
    ///     occupy the anchor cell — the constraint of SPEC § 5, step 4.
    ///   - seed: makes a given cycle reproducible, which is what lets the
    ///     harness scrub backwards and see the same thing twice.
    func layout(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed: UInt64
    ) throws -> MosaicLayout

    /// How the last mosaic scored, when the planner is the sort that can say.
    var lastStatistics: SolveStatistics? { get }
}

extension MosaicPlanner {
    public var lastStatistics: SolveStatistics? { nil }
}

/// Assigns tiles at random. It is not a photomosaic and does not pretend to be.
///
/// It stays because it is the only thing that works with no index at all: the
/// harness still has to run on synthetic photographs, and M10 will need
/// something to fall back on when the index is missing or empty.
public struct RandomMosaicPlanner: MosaicPlanner {
    public let pool: [PhotoID]
    public let seed: UInt64
    private let sequence: SubjectSequence

    public init(pool: [PhotoID], seed: UInt64 = 0x4D05_A1C0) {
        precondition(!pool.isEmpty, "a mosaic needs photographs to be made of")
        self.pool = pool
        self.seed = seed
        self.sequence = SubjectSequence(count: pool.count, seed: seed)
    }

    public func subject(ofCycle index: Int) -> PhotoID {
        pool[sequence.index(ofCycle: index)]
    }

    public func layout(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed: UInt64
    ) -> MosaicLayout {
        var rng = SplitMix64(seed: seed)

        var tiles = (0..<(rows * rows)).map { _ in
            TileAssignment(photo: pool[rng.next(upperBound: pool.count)])
        }

        let anchor = GridCell(
            column: rng.next(upperBound: rows),
            row: rng.next(upperBound: rows)
        )
        if let previousSubject {
            tiles[anchor.row * rows + anchor.column] = TileAssignment(photo: previousSubject)
        }

        return MosaicLayout(rows: rows, subject: subject, anchor: anchor, tiles: tiles)
    }
}
