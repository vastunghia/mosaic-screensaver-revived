import Foundation

/// What the index remembers about one photograph's colour: a `k × k` grid of
/// linear means over its canonical crop.
///
/// The shape is the one thing worth being careful about. A mosaic is `R` columns
/// by `R` rows of 16:9 tiles filling a 16:9 screen, so **a `k × k` subdivision of
/// a 16:9 crop yields `k²` sub-cells that are each themselves 16:9** — SPEC § 4's
/// self-similarity, one level down. A signature is therefore square in its cell
/// count for the same reason a mosaic is, and `k = 1` is precisely the average
/// colour of SPEC § 5 step 3.
///
/// That makes "pool signature" and "target grid" the same object at different
/// `k`, so matching on the mean and matching on structure are one code path with
/// a parameter rather than two algorithms.
///
/// It is stored in linear light, never in Lab: see `LinearRGB`.
public struct TileSignature: Equatable, Sendable {
    /// `k`: cells per side. A power of two, so `reduced(to:)` is always exact.
    public let side: Int

    /// `k²` cells, row-major, top-left first.
    public let cells: [LinearRGB]

    public init(side: Int, cells: [LinearRGB]) {
        precondition(side >= 1, "a signature needs at least one cell")
        precondition(side & (side - 1) == 0, "the side has to be a power of two")
        precondition(cells.count == side * side, "expected \(side * side) cells, got \(cells.count)")
        self.side = side
        self.cells = cells
    }

    public init(mean: LinearRGB) {
        self.init(side: 1, cells: [mean])
    }

    public subscript(column: Int, row: Int) -> LinearRGB {
        cells[row * side + column]
    }

    /// The average colour, which is the signature at `k = 1`.
    public var mean: LinearRGB {
        LinearRGB.mean(of: cells)
    }

    /// The same photograph described more coarsely. Exact, because the side is a
    /// power of two: every coarse cell covers a whole number of fine ones.
    ///
    /// Box reduction composes — `reduced(to: 2).reduced(to: 1) == reduced(to: 1)`
    /// — which is only true because the averaging happens in linear light. That
    /// property is what keeps a signature consistent with its own mean.
    public func reduced(to target: Int) -> TileSignature {
        precondition(target >= 1 && target <= side, "can only reduce, and only to at least one cell")
        precondition(side % target == 0, "the target side has to divide the current one")
        if target == side { return self }

        let block = side / target
        var reduced: [LinearRGB] = []
        reduced.reserveCapacity(target * target)

        for row in 0..<target {
            for column in 0..<target {
                var total = LinearRGB.black
                for y in (row * block)..<((row + 1) * block) {
                    for x in (column * block)..<((column + 1) * block) {
                        total = total + self[x, y]
                    }
                }
                reduced.append(total * (1 / Double(block * block)))
            }
        }
        return TileSignature(side: target, cells: reduced)
    }

    /// The cells in Lab, which is where comparison happens and averaging stops.
    public var labCells: [LabColor] {
        cells.map(LabColor.init)
    }
}

/// The target photograph of a cycle, sampled on the mosaic's own grid.
///
/// `rows` is `R`, `detail` is `k`, and the cells are an `(R·k) × (R·k)` grid over
/// the canonical crop — so one mosaic cell owns a `k × k` block of them, which is
/// exactly the shape of a `TileSignature` at that `k`. Matching a tile to a cell
/// is then comparing two objects of the same type.
///
/// Nothing here depends on the index: `R` is a setting the user can drag, so no
/// stored artefact may be shaped by it. The grid is computed when a cycle needs
/// it, from the one photograph it is about.
public struct TargetGrid: Equatable, Sendable {
    public let rows: Int
    public let detail: Int
    public let cells: [LinearRGB]

    public init(rows: Int, detail: Int, cells: [LinearRGB]) {
        precondition(rows >= 2, "a mosaic needs at least 2 rows")
        precondition(detail >= 1 && detail & (detail - 1) == 0, "detail has to be a power of two")
        precondition(
            cells.count == (rows * detail) * (rows * detail),
            "expected \((rows * detail) * (rows * detail)) cells, got \(cells.count)"
        )
        self.rows = rows
        self.detail = detail
        self.cells = cells
    }

    /// Cells per side of the whole grid: `R · k`.
    public var side: Int { rows * detail }

    /// One mosaic cell's block, in the same row-major order a `TileSignature`
    /// uses, so the two can be compared term by term.
    public func signature(of cell: GridCell) -> TileSignature {
        var block: [LinearRGB] = []
        block.reserveCapacity(detail * detail)
        for y in 0..<detail {
            let row = cell.row * detail + y
            for x in 0..<detail {
                block.append(cells[row * side + cell.column * detail + x])
            }
        }
        return TileSignature(side: detail, cells: block)
    }

    /// One mosaic cell's average colour — the quantity SPEC § 5 step 4 picks the
    /// anchor with.
    public func mean(of cell: GridCell) -> LinearRGB {
        signature(of: cell).mean
    }
}
