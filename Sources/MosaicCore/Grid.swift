import Foundation

/// One cell of the mosaic grid. Column 0, row 0 is the top-left cell.
public struct GridCell: Hashable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// A rectangular block of cells, as returned by culling. Empty when either
/// range is empty.
public struct GridCellRange: Equatable, Sendable {
    public let columns: Range<Int>
    public let rows: Range<Int>

    public init(columns: Range<Int>, rows: Range<Int>) {
        self.columns = columns
        self.rows = rows
    }

    public static let empty = GridCellRange(columns: 0..<0, rows: 0..<0)

    public var isEmpty: Bool { columns.isEmpty || rows.isEmpty }
    public var count: Int { columns.count * rows.count }

    public func forEach(_ body: (GridCell) -> Void) {
        for row in rows {
            for column in columns {
                body(GridCell(column: column, row: row))
            }
        }
    }
}

/// Maps between cells and mosaic space.
///
/// Because tiles share the screen's aspect ratio (SPEC § 4), a mosaic that fills
/// the screen is square in its cell count: `R` columns by `R` rows. In mosaic
/// space every cell is therefore exactly `1/R` on a side, and the geometry needs
/// no aspect ratio at all.
public struct GridGeometry: Equatable, Sendable {
    /// `R`: both the number of rows and the zoom factor of one cycle.
    public let rows: Int

    public init(rows: Int) {
        precondition(rows >= 2, "a mosaic needs at least 2 rows")
        self.rows = rows
    }

    public var cellCount: Int { rows * rows }

    /// The side of one cell in mosaic space.
    public var cellSide: Double { 1 / Double(rows) }

    public func contains(_ cell: GridCell) -> Bool {
        (0..<rows).contains(cell.column) && (0..<rows).contains(cell.row)
    }

    public func rect(of cell: GridCell) -> NormalizedRect {
        // Edges are computed as exact fractions rather than by adding a side
        // length to an origin: `2/5 + 1/5` lands on 0.6000000000000001, which is
        // past the boundary, and culling would then claim the next column of
        // every cell for ever.
        let rows = Double(rows)
        let x = Double(cell.column) / rows
        let y = Double(cell.row) / rows
        return NormalizedRect(
            x: x,
            y: y,
            width: Double(cell.column + 1) / rows - x,
            height: Double(cell.row + 1) / rows - y
        )
    }

    public func center(of cell: GridCell) -> NormalizedPoint {
        rect(of: cell).center
    }

    /// The cells a visible rectangle touches — the culling of SPEC § 6.
    ///
    /// This lives here, and not in the renderer, because it is arithmetic with
    /// awkward boundary cases and it deserves to be tested as arithmetic. Edges
    /// are half-open: a rectangle ending exactly on a cell boundary does not
    /// include the cell beyond it.
    public func cells(intersecting rect: NormalizedRect) -> GridCellRange {
        let columns = indices(from: rect.minX, to: rect.maxX)
        let rows = indices(from: rect.minY, to: rect.maxY)
        if columns.isEmpty || rows.isEmpty { return .empty }
        return GridCellRange(columns: columns, rows: rows)
    }

    /// How far past a boundary a rectangle has to reach before it counts as
    /// touching the next cell. Without it, arithmetic that lands a few ulps past
    /// an edge draws a whole extra row of tiles — invisibly, and for ever.
    private static let edgeTolerance = 1e-9

    private func indices(from lower: Double, to upper: Double) -> Range<Int> {
        guard upper > 0, lower < 1, upper > lower else { return 0..<0 }
        let scale = Double(rows)
        let epsilon = Self.edgeTolerance
        let first = max(0, Int((lower * scale + epsilon).rounded(.down)))
        let last = min(rows - 1, Int((upper * scale - epsilon).rounded(.up)) - 1)
        guard first <= last else { return 0..<0 }
        return first..<(last + 1)
    }
}
