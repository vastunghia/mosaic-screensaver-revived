import Foundation
import Testing
@testable import MosaicCore

@Suite("Tile signature")
struct TileSignatureTests {
    private func signature(side: Int, seed: UInt64 = 7) -> TileSignature {
        var rng = SplitMix64(seed: seed)
        return TileSignature(
            side: side,
            cells: (0..<(side * side)).map { _ in
                LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit())
            }
        )
    }

    private func expectClose(_ a: LinearRGB, _ b: LinearRGB, _ message: Comment) {
        // Not exact equality: box reduction sums the same values in different
        // groupings, and floating point addition does not associate. The point
        // of the property is that the two answers agree to the last few bits,
        // not that the bits are identical.
        #expect(abs(a.r - b.r) < 1e-15, message)
        #expect(abs(a.g - b.g) < 1e-15, message)
        #expect(abs(a.b - b.b) < 1e-15, message)
    }

    @Test("box reduction composes, so a signature agrees with its own mean")
    func reductionComposes() {
        let fine = signature(side: 8)
        expectClose(fine.reduced(to: 2).reduced(to: 1).mean, fine.reduced(to: 1).mean, "8 -> 2 -> 1")
        expectClose(fine.reduced(to: 4).reduced(to: 2).mean, fine.reduced(to: 2).mean, "8 -> 4 -> 2")
        for side in [1, 2, 4, 8] {
            expectClose(fine.reduced(to: side).mean, fine.mean, "mean survives reduction to \(side)")
        }
    }

    @Test("reducing to the same side changes nothing")
    func reducingToItself() {
        let fine = signature(side: 4)
        #expect(fine.reduced(to: 4) == fine)
    }

    @Test("a k by k subdivision of a 16:9 crop gives sub-cells that are 16:9 too")
    func subdivisionPreservesAspect() {
        // This is why a signature is square in its cell count, exactly as a
        // mosaic is (SPEC § 4). If it were not, a tile could not be compared
        // against a mosaic cell term by term.
        for k in [1, 2, 4, 8] {
            let cellWidth = CanonicalAspect.ratio / Double(k)
            let cellHeight = 1.0 / Double(k)
            #expect(abs(cellWidth / cellHeight - CanonicalAspect.ratio) < 1e-12, "k = \(k)")
        }
    }

    @Test("a target grid hands back one mosaic cell as a signature of the same shape")
    func targetGridBlocks() {
        let rows = 3
        let detail = 2
        let side = rows * detail
        let cells = (0..<(side * side)).map { index in
            LinearRGB(r: Double(index) / Double(side * side), g: 0, b: 0)
        }
        let grid = TargetGrid(rows: rows, detail: detail, cells: cells)

        let cell = GridCell(column: 1, row: 2)
        let block = grid.signature(of: cell)
        #expect(block.side == detail)

        // Row 2 of cells, column 1, at detail 2: source rows 4 and 5, columns 2
        // and 3 of a 6-wide grid.
        #expect(block[0, 0] == cells[4 * side + 2])
        #expect(block[1, 0] == cells[4 * side + 3])
        #expect(block[0, 1] == cells[5 * side + 2])
        #expect(block[1, 1] == cells[5 * side + 3])
        expectClose(grid.mean(of: cell), block.mean, "the cell mean is the block's mean")
    }

    @Test("detail 1 makes the target grid exactly one colour per mosaic cell")
    func detailOneIsTheAverageColour() {
        var rng = SplitMix64(seed: 99)
        let rows = 5
        let cells = (0..<(rows * rows)).map { _ in
            LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit())
        }
        let grid = TargetGrid(rows: rows, detail: 1, cells: cells)
        for row in 0..<rows {
            for column in 0..<rows {
                let cell = GridCell(column: column, row: row)
                #expect(grid.mean(of: cell) == cells[row * rows + column])
            }
        }
    }
}
