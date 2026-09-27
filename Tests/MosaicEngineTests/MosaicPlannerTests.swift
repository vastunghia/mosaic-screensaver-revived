import Foundation
import MosaicCore
import MosaicSolver
import Testing
@testable import MosaicEngine

/// A catalogue with no disk behind it, which is the point of the protocol: the
/// planner can be exercised without an index, a folder or a GPU.
private struct FakeCatalog: TileCatalog {
    var signatures: [String: TileSignature]
    var targets: [String: TargetGrid] = [:]

    var photos: [PhotoID] { signatures.keys.sorted().map(PhotoID.init) }

    func signature(for photo: PhotoID) -> TileSignature? {
        signatures[photo.rawValue]
    }

    func targetGrid(for photo: PhotoID, rows: Int, detail: Int) throws -> TargetGrid {
        if let ready = targets[photo.rawValue], ready.rows == rows, ready.detail == detail {
            return ready
        }
        // A deterministic grid derived from the name, so every photograph is a
        // different target and the same photograph is always the same target.
        var rng = SplitMix64(seed: UInt64(abs(photo.rawValue.hashValue % 100_000)))
        let side = rows * detail
        return TargetGrid(
            rows: rows, detail: detail,
            cells: (0..<(side * side)).map { _ in
                LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit())
            }
        )
    }
}

private func lattice(perAxis: Int) -> FakeCatalog {
    var signatures: [String: TileSignature] = [:]
    for r in 0..<perAxis {
        for g in 0..<perAxis {
            for b in 0..<perAxis {
                let colour = LinearRGB(
                    r: Double(r) / Double(perAxis - 1),
                    g: Double(g) / Double(perAxis - 1),
                    b: Double(b) / Double(perAxis - 1)
                )
                // As fine as the index stores them, so the planner's standard
                // detail can reduce them.
                signatures["tile-\(r)\(g)\(b)"] = TileSignature(
                    side: 4, cells: Array(repeating: colour, count: 16)
                )
            }
        }
    }
    return FakeCatalog(signatures: signatures)
}

@Suite("Mosaic planner")
struct MosaicPlannerTests {

    @Test("no cycle depicts the photograph the one before it did")
    func subjectsNeverRepeat() throws {
        // B and C being the same photograph would put C inside its own mosaic
        // and make the whole cycle look like it went nowhere.
        let solved = SolvedMosaicPlanner(catalog: lattice(perAxis: 4))
        let random = RandomMosaicPlanner(pool: (0..<40).map { PhotoID("p\($0)") })

        for planner in [solved as any MosaicPlanner, random] {
            for index in 1..<300 {
                #expect(
                    planner.subject(ofCycle: index) != planner.subject(ofCycle: index - 1),
                    "cycle \(index)"
                )
            }
        }
    }

    @Test("the subject of a cycle does not depend on when it is asked for")
    func subjectsAreStable() {
        // The engine asks for cycle n as "current" and again as "previous" a
        // cycle later. If the answer drifted, the anchor assertion in
        // CycleEngine.frame would fire — or worse, would not.
        let planner = SolvedMosaicPlanner(catalog: lattice(perAxis: 4))
        let first = (0..<50).map { planner.subject(ofCycle: $0) }
        let again = (0..<50).reversed().map { planner.subject(ofCycle: $0) }.reversed()
        #expect(first == Array(again))
    }

    @Test("the previous cycle's photograph lands in the anchor cell")
    func anchorContract() throws {
        let planner = SolvedMosaicPlanner(catalog: lattice(perAxis: 4))
        for index in 1..<6 {
            let previous = planner.subject(ofCycle: index - 1)
            let layout = try planner.plan(
                rows: 8, subject: planner.subject(ofCycle: index),
                previousSubject: previous, seed: UInt64(index)
            ).layout
            // This is exactly what CycleEngine.frame asserts on every frame.
            #expect(layout.anchoredPhoto == previous, "cycle \(index)")
            #expect(layout.tiles.count == 64)
        }
    }

    @Test("the same inputs plan the same mosaic, in any host")
    func determinism() throws {
        let catalog = lattice(perAxis: 4)
        func plan() throws -> MosaicLayout {
            try SolvedMosaicPlanner(catalog: catalog).plan(
                rows: 10, subject: PhotoID("tile-000"), previousSubject: PhotoID("tile-333"), seed: 9
            ).layout
        }
        #expect(try plan() == (try plan()))
    }

    @Test("statistics travel with the mosaic they describe")
    func statisticsTravelWithTheirMosaic() throws {
        // Written down because it caused a real wrong answer. The planner used
        // to keep "its last solve" on the side, and the lookahead builds cycle
        // n+1 before cycle n-1, so that value described another picture — the
        // worst kind of wrong, since the numbers exist to be compared.
        let catalog = lattice(perAxis: 4)
        let planner = SolvedMosaicPlanner(catalog: catalog)

        let wide = try planner.plan(rows: 20, subject: PhotoID("tile-000"), previousSubject: nil, seed: 1)
        let narrow = try planner.plan(rows: 4, subject: PhotoID("tile-111"), previousSubject: nil, seed: 1)

        #expect(wide.statistics?.cellCount == 400, "still its own after a later solve")
        #expect(narrow.statistics?.cellCount == 16)
    }

    @Test("a catalogue with nothing to match on says so instead of pretending")
    func unusableCatalog() {
        let empty = SolvedMosaicPlanner(catalog: FakeCatalog(signatures: [:]))
        #expect(!empty.isUsable)
        #expect(empty.poolSize == 0)

        // Asking it anything still has to be survivable: the saver may run
        // before the app has ever built an index.
        #expect(empty.subject(ofCycle: 7) == PhotoID(""))
        #expect(throws: MosaicSolverError.self) {
            _ = try empty.plan(rows: 8, subject: PhotoID("x"), previousSubject: nil, seed: 1)
        }

        // A photograph without a signature is left out of the pool rather than
        // guessed at.
        var partial = lattice(perAxis: 3)
        partial.signatures["no-signature-here"] = nil
        let planner = SolvedMosaicPlanner(catalog: partial)
        #expect(planner.isUsable)
        #expect(planner.poolSize == 27)
    }
}
