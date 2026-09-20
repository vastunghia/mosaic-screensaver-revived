import Testing
@testable import MosaicCore

@Suite("Grid geometry")
struct GridGeometryTests {
    @Test("a cell's rectangle is 1/R on a side and sits where its indices say")
    func cellRects() {
        let grid = GridGeometry(rows: 4)
        #expect(grid.cellSide == 0.25)
        #expect(grid.cellCount == 16)

        let topLeft = grid.rect(of: GridCell(column: 0, row: 0))
        #expect(topLeft == NormalizedRect(x: 0, y: 0, width: 0.25, height: 0.25))

        let bottomRight = grid.rect(of: GridCell(column: 3, row: 3))
        #expect(bottomRight.maxX == 1)
        #expect(bottomRight.maxY == 1)

        #expect(grid.center(of: GridCell(column: 1, row: 2)) == NormalizedPoint(x: 0.375, y: 0.625))
    }

    @Test("the whole mosaic is visible at the end of a cycle, one cell at the start")
    func cullingExtremes() {
        let grid = GridGeometry(rows: 5)

        let all = grid.cells(intersecting: .unit)
        #expect(all.count == 25)

        let one = grid.cells(intersecting: grid.rect(of: GridCell(column: 2, row: 3)))
        #expect(one.count == 1)
        #expect(one.columns == 2..<3)
        #expect(one.rows == 3..<4)
    }

    @Test("a rectangle ending exactly on a boundary does not claim the next cell")
    func cullingOnExactBoundaries() {
        let grid = GridGeometry(rows: 2)

        // Exactly the left half: columns {0}, not {0, 1}.
        let leftHalf = NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(grid.cells(intersecting: leftHalf).columns == 0..<1)

        // Starting exactly on the boundary: columns {1}.
        let rightHalf = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(grid.cells(intersecting: rightHalf).columns == 1..<2)

        // A hair over the boundary reaches both.
        let straddling = NormalizedRect(x: 0.49, y: 0, width: 0.02, height: 1)
        #expect(grid.cells(intersecting: straddling).columns == 0..<2)
    }

    @Test("every cell's own rectangle selects exactly that cell, at every R")
    func everyCellSelectsItself() {
        // The arithmetic that produces a cell's rectangle and the arithmetic
        // that culls against it have to agree exactly. They did not: at R = 5
        // the rectangle of column 2 ended on 0.6000000000000001 and claimed
        // column 3 as well. Nothing on screen would have looked obviously wrong.
        for rows in [2, 3, 5, 7, 12, 20, 37, 50] {
            let grid = GridGeometry(rows: rows)
            for row in 0..<rows {
                for column in 0..<rows {
                    let cell = GridCell(column: column, row: row)
                    let selected = grid.cells(intersecting: grid.rect(of: cell))
                    #expect(selected.count == 1, "R = \(rows), cell \(cell)")
                    #expect(selected.columns == column..<(column + 1), "R = \(rows), cell \(cell)")
                    #expect(selected.rows == row..<(row + 1), "R = \(rows), cell \(cell)")
                }
            }
        }
    }

    @Test("a rectangle off the mosaic yields nothing, and one hanging off the edge is clamped")
    func cullingOutside() {
        let grid = GridGeometry(rows: 4)

        #expect(grid.cells(intersecting: NormalizedRect(x: 1.5, y: 0, width: 0.2, height: 0.2)).isEmpty)
        #expect(grid.cells(intersecting: NormalizedRect(x: -0.9, y: 0, width: 0.2, height: 0.2)).isEmpty)

        // The camera regularly sees past the edge of the mosaic near the end of
        // a cycle; that must clamp, not overflow the tile array.
        let overhanging = NormalizedRect(x: -0.5, y: -0.5, width: 2, height: 2)
        let cells = grid.cells(intersecting: overhanging)
        #expect(cells.columns == 0..<4)
        #expect(cells.rows == 0..<4)
    }

    @Test("a camera rectangle is square in mosaic space, because a mosaic is a screenful")
    func centeredRects() {
        let rect = NormalizedRect.centered(on: NormalizedPoint(x: 0.5, y: 0.5), width: 0.4)
        #expect(rect.width == rect.height)
        #expect(rect.center == NormalizedPoint(x: 0.5, y: 0.5))
    }
}
