import Testing
@testable import MosaicCore

@Suite("Mosaic layout")
struct MosaicLayoutTests {
    private func layout(rows: Int = 3) -> MosaicLayout {
        let tiles = (0..<(rows * rows)).map { TileAssignment(photo: PhotoID("p\($0)")) }
        return MosaicLayout(
            rows: rows,
            subject: PhotoID("subject"),
            anchor: GridCell(column: 1, row: 2),
            tiles: tiles
        )
    }

    @Test("tiles are stored row-major")
    func rowMajor() {
        let mosaic = layout()
        #expect(mosaic[GridCell(column: 0, row: 0)].photo == PhotoID("p0"))
        #expect(mosaic[GridCell(column: 2, row: 0)].photo == PhotoID("p2"))
        #expect(mosaic[GridCell(column: 0, row: 1)].photo == PhotoID("p3"))
        #expect(mosaic[GridCell(column: 1, row: 2)].photo == PhotoID("p7"))
    }

    @Test("the anchored photograph is the one in the anchor cell")
    func anchoredPhoto() {
        let mosaic = layout()
        #expect(mosaic.anchoredPhoto == mosaic[mosaic.anchor].photo)
        #expect(mosaic.geometry.contains(mosaic.anchor))
    }

    @Test("identifiers are carried whole, never parsed")
    func hostileIdentifiers() {
        // The original broke on these characters in file names (SPEC § 5). The
        // point here is that nothing in the pipeline is tempted to interpret them.
        let nasty = PhotoID("100%$#@/../ ùnicode \u{1F4F7}.jpg")
        let mosaic = MosaicLayout(
            rows: 2,
            subject: nasty,
            anchor: GridCell(column: 0, row: 0),
            tiles: Array(repeating: TileAssignment(photo: nasty), count: 4)
        )
        #expect(mosaic.subject.rawValue == "100%$#@/../ ùnicode \u{1F4F7}.jpg")
        #expect(mosaic.anchoredPhoto == nasty)
    }
}
