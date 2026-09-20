import Foundation
import Testing
@testable import CycleEngine
import MosaicCore

@Suite("Cycle engine")
struct CycleEngineBehaviourTests {
    let settings = MosaicSettings(rows: 10, cycleDuration: 20)
    var engine: CycleEngine { CycleEngine(settings: settings) }

    /// Two mosaics that chain the way the engine will chain them: the second one
    /// holds the first one's subject in its anchor cell.
    private func chain() -> (first: MosaicLayout, second: MosaicLayout) {
        let rows = settings.rows
        let subjectA = PhotoID("A")
        let subjectB = PhotoID("B")

        let first = MosaicLayout(
            rows: rows,
            subject: subjectA,
            anchor: GridCell(column: 1, row: 1),
            tiles: (0..<(rows * rows)).map { TileAssignment(photo: PhotoID("a\($0)")) }
        )

        let anchor = GridCell(column: 6, row: 2)
        var tiles = (0..<(rows * rows)).map { TileAssignment(photo: PhotoID("b\($0)")) }
        tiles[anchor.row * rows + anchor.column] = TileAssignment(photo: subjectA)
        let second = MosaicLayout(rows: rows, subject: subjectB, anchor: anchor, tiles: tiles)

        return (first, second)
    }

    @Test("time splits into a cycle index and a position, with no gap between cycles")
    func position() {
        let engine = engine
        #expect(engine.position(at: 0) == CyclePosition(index: 0, u: 0))
        #expect(engine.position(at: 10).u == 0.5)
        #expect(engine.position(at: 20) == CyclePosition(index: 1, u: 0))
        #expect(engine.position(at: 45).index == 2)

        // Time before zero is not a real case, but it must not produce a
        // discontinuity if a harness scrubs backwards past the start.
        #expect(engine.position(at: -1).index == -1)
        #expect(abs(engine.position(at: -1).u - 0.95) < 1e-12)
    }

    @Test("the crossfade starts opaque, ends transparent and never goes back up")
    func crossfade() {
        let engine = engine
        #expect(engine.crossfade(at: 0) == 1)
        #expect(engine.crossfade(at: settings.crossfadeDuration) == 0)
        #expect(engine.crossfade(at: 0.5) == 0)

        var previous = 1.0
        for u in stride(from: 0.0, through: 1.0, by: 0.001) {
            let alpha = engine.crossfade(at: u)
            #expect(alpha <= previous + 1e-12, "the crossfade went back up at u = \(u)")
            #expect(alpha >= 0 && alpha <= 1)
            previous = alpha
        }
    }

    @Test("the end of one cycle and the start of the next show the same picture")
    func junction() {
        let engine = engine
        let (first, second) = chain()
        let T = settings.cycleDuration

        // At the end of cycle 0 the whole of the first mosaic fills the screen.
        let ending = engine.frame(at: T - 1e-9, current: first, previous: nil)
        let end = ending.camera.visibleRect
        #expect(abs(end.width - 1) < 1e-6)
        #expect(abs(end.minX) < 1e-6)
        #expect(abs(end.minY) < 1e-6)

        // At the start of cycle 1 the screen shows exactly the cell of the
        // second mosaic that holds the first mosaic's photograph — the same
        // picture, now understood as a tile.
        let starting = engine.frame(at: T, current: second, previous: first)
        let start = starting.camera.visibleRect
        let anchorRect = second.geometry.rect(of: second.anchor)
        #expect(abs(start.minX - anchorRect.minX) < 1e-12)
        #expect(abs(start.minY - anchorRect.minY) < 1e-12)
        #expect(abs(start.width - anchorRect.width) < 1e-12)

        #expect(second.anchoredPhoto == first.subject)
        #expect(starting.previous?.photo == first.subject)
        #expect(starting.previous?.mosaicAlpha == 1)
    }

    @Test("one tile is on screen at the start of a cycle, all R squared at the end")
    func visibleCells() {
        let engine = engine
        let (_, second) = chain()

        #expect(engine.frame(at: 0, current: second, previous: nil).visibleCells.count == 1)

        let last = engine.frame(
            at: settings.cycleDuration - 1e-9,
            current: second,
            previous: nil
        )
        #expect(last.visibleCells.count == settings.rows * settings.rows)
    }

    @Test("the mosaic needed next is already being asked for")
    func lookahead() {
        let engine = engine
        #expect(engine.cyclesNeeded(at: 0) == 0...1)
        #expect(engine.cyclesNeeded(at: settings.cycleDuration * 3 + 1) == 3...4)
    }
}
