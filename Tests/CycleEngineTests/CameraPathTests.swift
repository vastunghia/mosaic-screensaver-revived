import Foundation
import Testing
@testable import CycleEngine
import MosaicCore

@Suite("Camera path")
struct CameraPathTests {
    private func path(rows: Int, anchor: GridCell) -> CameraPath {
        CameraPath(settings: MosaicSettings(rows: rows), anchor: anchor)
    }

    @Test("the cycle is a pure scaling: one point of the mosaic never moves on screen")
    func pureScaling() {
        // This is the test that matters. Interpolating the camera centre between
        // the anchor cell and the middle of the mosaic hits both endpoints too,
        // and looks plausible — but it adds a sideways drift that SPEC never
        // asks for. Here the screen position of the invariant point has to be
        // the same number at every u.
        for anchor in [GridCell(column: 0, row: 0), GridCell(column: 7, row: 3), GridCell(column: 19, row: 19)] {
            let path = path(rows: 20, anchor: anchor)
            let expected = path.invariantScreenPosition

            for u in stride(from: 0.0, through: 1.0, by: 0.01) {
                let seen = path.camera(at: u).project(path.invariantPoint)
                #expect(abs(seen.x - expected.x) < 1e-12, "u = \(u), anchor \(anchor)")
                #expect(abs(seen.y - expected.y) < 1e-12, "u = \(u), anchor \(anchor)")
            }
        }
    }

    @Test("the fixed point always falls inside the frame")
    func fixedPointOnScreen() {
        for rows in [2, 5, 20, 50] {
            for row in 0..<rows {
                for column in 0..<rows {
                    let k = path(rows: rows, anchor: GridCell(column: column, row: row))
                        .invariantScreenPosition
                    #expect(abs(k.x) <= 0.5 + 1e-12, "R = \(rows), cell (\(column), \(row))")
                    #expect(abs(k.y) <= 0.5 + 1e-12, "R = \(rows), cell (\(column), \(row))")
                }
            }
        }
    }

    @Test("the screen shows exactly the anchor cell at u = 0 and the whole mosaic at u = 1")
    func endpoints() {
        let rows = 12
        let anchor = GridCell(column: 4, row: 9)
        let grid = GridGeometry(rows: rows)
        let path = path(rows: rows, anchor: anchor)

        let start = path.camera(at: 0).visibleRect
        let cell = grid.rect(of: anchor)
        #expect(abs(start.minX - cell.minX) < 1e-12)
        #expect(abs(start.minY - cell.minY) < 1e-12)
        #expect(abs(start.width - cell.width) < 1e-12)

        let end = path.camera(at: 1).visibleRect
        #expect(abs(end.minX) < 1e-12)
        #expect(abs(end.minY) < 1e-12)
        #expect(abs(end.width - 1) < 1e-12)
    }

    @Test("the camera is still at both ends of a cycle, so the join is C-one continuous")
    func cameraStopsAtTheJoin() {
        let path = path(rows: 20, anchor: GridCell(column: 3, row: 15))
        let h = 1e-6

        for (a, b) in [(0.0, h), (1.0 - h, 1.0)] {
            let first = path.camera(at: a).center
            let second = path.camera(at: b).center
            #expect(abs(second.x - first.x) / h < 1e-4)
            #expect(abs(second.y - first.y) / h < 1e-4)
        }
    }
}
