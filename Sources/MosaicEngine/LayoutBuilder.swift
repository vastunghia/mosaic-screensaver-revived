import MosaicCore

/// Builds the mosaic for one cycle.
///
/// The real one is M3, which picks tiles by colour distance in CIE Lab. This
/// protocol exists so that milestone 1 can run on something far stupider
/// without the rest of the engine knowing the difference.
public protocol LayoutBuilder: Sendable {
    /// - Parameters:
    ///   - subject: the photograph this mosaic depicts from far away.
    ///   - previousSubject: the photograph of the cycle before, which has to
    ///     occupy the anchor cell — the constraint of SPEC § 5, step 4.
    ///   - seed: makes a given cycle reproducible, which is what lets the
    ///     harness scrub backwards and see the same thing twice.
    func layout(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        pool: [PhotoID],
        seed: UInt64
    ) -> MosaicLayout
}

/// Assigns tiles at random. It is not a photomosaic and does not pretend to be:
/// it exists so the movement can be judged before the tile choice is any good,
/// which is the whole point of splitting milestone 1 from milestone 2.
public struct RandomLayoutBuilder: LayoutBuilder {
    public init() {}

    public func layout(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        pool: [PhotoID],
        seed: UInt64
    ) -> MosaicLayout {
        precondition(!pool.isEmpty, "a mosaic needs photographs to be made of")
        var rng = SplitMix64(seed: seed)

        var tiles = (0..<(rows * rows)).map { _ in
            TileAssignment(photo: pool[Int(rng.next() % UInt64(pool.count))])
        }

        let anchor = GridCell(
            column: Int(rng.next() % UInt64(rows)),
            row: Int(rng.next() % UInt64(rows))
        )
        if let previousSubject {
            tiles[anchor.row * rows + anchor.column] = TileAssignment(photo: previousSubject)
        }

        return MosaicLayout(rows: rows, subject: subject, anchor: anchor, tiles: tiles)
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
