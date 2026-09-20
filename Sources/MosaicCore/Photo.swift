import Foundation

/// A stable, opaque handle on one photograph.
///
/// Opaque is the operative word. The original screen saver broke on file names
/// containing `%`, `$`, `#` or `@` (SPEC § 5) because identifiers were being
/// interpolated or URL-encoded somewhere along the way. Nothing in this project
/// may parse, escape or split a PhotoID: it is carried, compared and hashed.
public struct PhotoID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What one cell of a mosaic shows.
public struct TileAssignment: Equatable, Sendable {
    public let photo: PhotoID

    public init(photo: PhotoID) {
        self.photo = photo
    }
}

/// A finished mosaic: which photograph each cell shows, plus the two facts the
/// cycle needs to zoom out of it.
///
/// It is entirely precomputed before the zoom begins, because SPEC § 2 requires
/// the tiles to look as though they had always been there.
public struct MosaicLayout: Equatable, Sendable {
    /// `R`. Also the number of columns, and the zoom factor of the cycle.
    public let rows: Int

    /// The photograph this mosaic depicts when seen from far enough away.
    public let subject: PhotoID

    /// The cell holding the previous cycle's photograph, which the camera starts
    /// centred on (SPEC § 5, step 4).
    public let anchor: GridCell

    /// Row-major, `rows * rows` entries.
    public let tiles: [TileAssignment]

    public init(rows: Int, subject: PhotoID, anchor: GridCell, tiles: [TileAssignment]) {
        precondition(rows >= 2, "a mosaic needs at least 2 rows")
        precondition(tiles.count == rows * rows, "expected \(rows * rows) tiles, got \(tiles.count)")
        precondition(
            (0..<rows).contains(anchor.column) && (0..<rows).contains(anchor.row),
            "anchor \(anchor) is outside a \(rows)x\(rows) grid"
        )
        self.rows = rows
        self.subject = subject
        self.anchor = anchor
        self.tiles = tiles
    }

    public var geometry: GridGeometry { GridGeometry(rows: rows) }

    public subscript(cell: GridCell) -> TileAssignment {
        tiles[cell.row * rows + cell.column]
    }

    /// The photograph the anchor cell shows: the subject of the previous cycle's
    /// mosaic.
    public var anchoredPhoto: PhotoID { self[anchor].photo }
}
