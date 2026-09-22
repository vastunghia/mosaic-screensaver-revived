import Foundation
import MosaicCore
import Testing
@testable import MosaicSolver

@Suite("Mosaic solver")
struct MosaicSolverTests {

    // MARK: - Fixtures

    /// A pool whose colours are a lattice in linear RGB, so distances are known
    /// and a denser lattice is strictly a better pool.
    private func latticePool(perAxis: Int, detail: Int = 1) -> [PoolEntry] {
        var entries: [PoolEntry] = []
        for r in 0..<perAxis {
            for g in 0..<perAxis {
                for b in 0..<perAxis {
                    let colour = LinearRGB(
                        r: Double(r) / Double(perAxis - 1),
                        g: Double(g) / Double(perAxis - 1),
                        b: Double(b) / Double(perAxis - 1)
                    )
                    entries.append(PoolEntry(
                        id: PhotoID("lattice:\(r)-\(g)-\(b)"),
                        signature: TileSignature(
                            side: detail,
                            cells: Array(repeating: colour, count: detail * detail)
                        )
                    ))
                }
            }
        }
        return entries
    }

    private func randomTarget(rows: Int, detail: Int = 1, seed: UInt64 = 1) -> TargetGrid {
        var rng = SplitMix64(seed: seed)
        let side = rows * detail
        return TargetGrid(
            rows: rows,
            detail: detail,
            cells: (0..<(side * side)).map { _ in
                LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit())
            }
        )
    }

    private func uniformTarget(rows: Int, colour: LinearRGB, detail: Int = 1) -> TargetGrid {
        let side = rows * detail
        return TargetGrid(
            rows: rows,
            detail: detail,
            cells: Array(repeating: colour, count: side * side)
        )
    }

    /// Nearest neighbour, recomputed the obvious slow way, for the optimality
    /// test to check the fast one against.
    private func nearest(to cell: LabColor, in pool: [PoolEntry]) -> PhotoID {
        var best = Double.infinity
        var chosen = pool[0].id
        for entry in pool {
            let distance = LabColor(entry.signature.mean).squaredDeltaE(to: cell)
            if distance < best {
                best = distance
                chosen = entry.id
            }
        }
        return chosen
    }

    private var unconstrained: SolverOptions {
        SolverOptions(repetitionSpacing: 0, repetitionPenalty: 0, maximumUses: .max)
    }

    // MARK: - Structure

    @Test("every cell is assigned, at every R, and the layout's own rules hold")
    func structuralInvariants() throws {
        let pool = latticePool(perAxis: 4)
        for rows in [2, 3, 7, 16, 30] {
            let result = try MosaicSolver.solve(
                target: randomTarget(rows: rows),
                subject: PhotoID("C"),
                previousSubject: pool[5].id,
                pool: pool,
                options: SolverOptions(repetitionSpacing: 2),
                seed: 42
            )
            let layout = result.layout
            #expect(layout.rows == rows)
            #expect(layout.tiles.count == rows * rows)
            #expect(layout.geometry.contains(layout.anchor))
            #expect(result.statistics.cellCount == rows * rows)
        }
    }

    @Test("the per-cell errors are the tiles' own, and the headline numbers summarise them")
    func perCellErrors() throws {
        // The error map is drawn from these, so they have to be recomputable from
        // the layout alone. A map built from anything else would show where the
        // solver thinks it went wrong, not where it did.
        let pool = latticePool(perAxis: 4)
        let rows = 12
        let target = randomTarget(rows: rows, seed: 3)
        let result = try MosaicSolver.solve(
            target: target,
            subject: PhotoID("C"),
            previousSubject: pool[9].id,
            pool: pool,
            options: SolverOptions(repetitionSpacing: 2),
            seed: 11
        )
        let statistics = result.statistics
        #expect(statistics.cellDeltaE.count == rows * rows)

        for row in 0..<rows {
            for column in 0..<rows {
                let index = row * rows + column
                let tile = result.layout.tiles[index].photo
                let entry = try #require(pool.first { $0.id == tile })
                let expected = LabColor(target.signature(of: GridCell(column: column, row: row)).mean)
                    .deltaE(to: LabColor(entry.signature.mean))
                #expect(abs(statistics.cellDeltaE[index] - expected) < 1e-9)
            }
        }

        let squares = statistics.cellDeltaE.reduce(0) { $0 + $1 * $1 }
        let rms = (squares / Double(rows * rows)).squareRoot()
        #expect(abs(rms - statistics.rootMeanSquareDeltaE) < 1e-9)
        #expect(statistics.cellDeltaE.max() == statistics.maximumDeltaE)
    }

    @Test("B sits in the anchor cell and in no other, as SPEC § 5 step 4 requires")
    func theAnchorHoldsBAlone() throws {
        let pool = latticePool(perAxis: 5)
        let b = pool[60].id
        for rows in [4, 9, 20] {
            let layout = try MosaicSolver.solve(
                target: randomTarget(rows: rows, seed: UInt64(rows)),
                subject: PhotoID("C"),
                previousSubject: b,
                pool: pool,
                options: SolverOptions(repetitionSpacing: 2),
                seed: 7
            ).layout

            #expect(layout.anchoredPhoto == b, "R = \(rows)")
            let appearances = layout.tiles.filter { $0.photo == b }.count
            #expect(appearances == 1, "B appears \(appearances) times at R = \(rows)")
        }
    }

    // MARK: - Correctness

    @Test("with no constraints every cell holds the globally nearest photograph")
    func optimality() throws {
        // The definitive correctness test: strip the spacing, the penalty and the
        // cap, and the answer is a plain nearest neighbour per cell, recomputed
        // here independently. Everything else the solver does is a departure
        // from this baseline that another test has to justify.
        let pool = latticePool(perAxis: 5)
        let rows = 12
        let target = randomTarget(rows: rows, seed: 314)

        let result = try MosaicSolver.solve(
            target: target,
            subject: PhotoID("C"),
            previousSubject: nil,
            pool: pool,
            options: unconstrained,
            seed: 5
        )

        for row in 0..<rows {
            for column in 0..<rows {
                let cell = GridCell(column: column, row: row)
                let wanted = nearest(to: LabColor(target.mean(of: cell)), in: pool)
                #expect(result.layout[cell].photo == wanted, "cell \(column),\(row)")
            }
        }
    }

    @Test("the anchor is the cell nearest B, not the first one that ties")
    func anchorIsTheArgmin() throws {
        let pool = latticePool(perAxis: 4)
        let b = pool[20]
        let rows = 6

        // A target that is far from B everywhere except one cell, which is B.
        var cells = Array(repeating: LinearRGB(r: 1, g: 1, b: 1), count: rows * rows)
        let wanted = GridCell(column: 4, row: 1)
        cells[wanted.row * rows + wanted.column] = b.signature.mean

        let layout = try MosaicSolver.solve(
            target: TargetGrid(rows: rows, detail: 1, cells: cells),
            subject: PhotoID("C"),
            previousSubject: b.id,
            pool: pool,
            options: SolverOptions(repetitionSpacing: 1),
            seed: 11
        ).layout

        #expect(layout.anchor == wanted)
    }

    @Test("on a flat target the anchor moves with the seed, instead of always the corner")
    func anchorTiesAreBrokenWithTheSeed() throws {
        // Without a seeded tie-break, argmin returns the first cell and the
        // camera starts in the top-left corner on every single cycle. On a sky
        // or a wall that is thousands of cells tying, so it is not a corner case.
        let pool = latticePool(perAxis: 4)
        let b = pool[30]
        let rows = 8

        var anchors: Set<GridCell> = []
        for seed in 0..<200 {
            let layout = try MosaicSolver.solve(
                target: uniformTarget(rows: rows, colour: b.signature.mean),
                subject: PhotoID("C"),
                previousSubject: b.id,
                pool: pool,
                options: SolverOptions(repetitionSpacing: 1),
                seed: UInt64(seed)
            ).layout
            anchors.insert(layout.anchor)
        }
        #expect(anchors.count > 20, "only \(anchors.count) distinct anchors out of 200 seeds")
    }

    // MARK: - Repetition

    @Test("no two cells within the spacing hold the same photograph")
    func spacingIsRespected() throws {
        let pool = latticePool(perAxis: 6)
        let rows = 24
        for spacing in 0...5 {
            let layout = try MosaicSolver.solve(
                target: randomTarget(rows: rows, seed: UInt64(spacing) &+ 100),
                subject: PhotoID("C"),
                previousSubject: pool[99].id,
                pool: pool,
                options: SolverOptions(repetitionSpacing: spacing),
                seed: 3
            ).layout

            guard spacing > 0 else { continue }
            for row in 0..<rows {
                for column in 0..<rows {
                    let here = layout[GridCell(column: column, row: row)].photo
                    for y in row...min(rows - 1, row + spacing) {
                        for x in max(0, column - spacing)...min(rows - 1, column + spacing) {
                            if y == row, x <= column { continue }
                            let there = layout[GridCell(column: x, row: y)].photo
                            #expect(here != there, "spacing \(spacing): \(column),\(row) and \(x),\(y)")
                        }
                    }
                }
            }
        }
    }

    @Test("the usage cap is never exceeded when the pool can cover the grid")
    func usageCap() throws {
        let pool = latticePool(perAxis: 4)   // 64 photographs
        let rows = 20                        // 400 cells
        let cap = 12                         // 64 * 12 = 768 >= 400
        let result = try MosaicSolver.solve(
            target: randomTarget(rows: rows, seed: 8),
            subject: PhotoID("C"),
            previousSubject: pool[1].id,
            pool: pool,
            options: SolverOptions(repetitionSpacing: 2, maximumUses: cap),
            seed: 17
        )
        #expect(result.statistics.maximumUses <= cap)
    }

    @Test("the repetition penalty is what actually spreads a flat target out")
    func penaltySpreadsAFlatTarget() throws {
        // Spacing alone bounds repetition only locally. On a target with almost
        // no variation a greedy match collapses onto a handful of photographs,
        // and that is what the eye sees first.
        let pool = latticePool(perAxis: 6)
        let rows = 24
        let target = uniformTarget(rows: rows, colour: LinearRGB(r: 0.2, g: 0.4, b: 0.75))

        func distinct(penalty: Double) throws -> Int {
            try MosaicSolver.solve(
                target: target,
                subject: PhotoID("C"),
                previousSubject: nil,
                pool: pool,
                options: SolverOptions(repetitionSpacing: 3, repetitionPenalty: penalty, maximumUses: .max),
                seed: 2
            ).statistics.distinctPhotos
        }

        let withoutPenalty = try distinct(penalty: 0)
        let withPenalty = try distinct(penalty: 2)
        #expect(withPenalty > withoutPenalty * 2, "\(withoutPenalty) -> \(withPenalty)")
    }

    // MARK: - Quality

    @Test("a denser pool gives a closer mosaic, at every step")
    func qualityImprovesMonotonically() throws {
        // Quality asserted without a magic constant: the absolute error depends
        // on the fixtures, but it has to fall every time the pool gets finer.
        let rows = 16
        let target = randomTarget(rows: rows, seed: 271)
        var previous = Double.infinity
        for perAxis in [2, 3, 4, 5, 6] {
            let error = try MosaicSolver.solve(
                target: target,
                subject: PhotoID("C"),
                previousSubject: nil,
                pool: latticePool(perAxis: perAxis),
                options: unconstrained,
                seed: 1
            ).statistics.rootMeanSquareDeltaE
            #expect(error < previous, "\(perAxis)^3: \(error) was not below \(previous)")
            previous = error
        }
    }

    @Test("detail 2 sees structure that detail 1 cannot, which is the point of k")
    func structureMatchingWorks() throws {
        // Two photographs with the same average colour and opposite structure,
        // against a target that alternates between them. At k = 1 they are
        // indistinguishable by construction; at k = 2 the solver must get every
        // cell right. The test proves the structural term works *and* that it
        // matters, which a test of either alone would not.
        let dark = LinearRGB(r: 0.05, g: 0.05, b: 0.05)
        let light = LinearRGB(r: 0.9, g: 0.9, b: 0.9)

        let leftDark = TileSignature(side: 2, cells: [dark, light, dark, light])
        let leftLight = TileSignature(side: 2, cells: [light, dark, light, dark])
        let pool = [
            PoolEntry(id: PhotoID("left-dark"), signature: leftDark),
            PoolEntry(id: PhotoID("left-light"), signature: leftLight),
        ]

        let rows = 8
        func target(detail: Int) -> TargetGrid {
            let side = rows * detail
            var cells = [LinearRGB](repeating: dark, count: side * side)
            for row in 0..<rows {
                for column in 0..<rows {
                    let wantsLeftDark = (row + column).isMultiple(of: 2)
                    for y in 0..<detail {
                        for x in 0..<detail {
                            let leftHalf = x < detail / 2 || detail == 1
                            let isDark = wantsLeftDark == leftHalf
                            cells[(row * detail + y) * side + column * detail + x] = isDark ? dark : light
                        }
                    }
                }
            }
            return TargetGrid(rows: rows, detail: detail, cells: cells)
        }

        func correctCells(detail: Int) throws -> Int {
            let layout = try MosaicSolver.solve(
                target: target(detail: detail),
                subject: PhotoID("C"),
                previousSubject: nil,
                pool: pool,
                options: SolverOptions(
                    detail: detail, repetitionSpacing: 0, repetitionPenalty: 0, maximumUses: .max
                ),
                seed: 4
            ).layout

            var correct = 0
            for row in 0..<rows {
                for column in 0..<rows {
                    let wanted = (row + column).isMultiple(of: 2) ? "left-dark" : "left-light"
                    if layout[GridCell(column: column, row: row)].photo.rawValue == wanted { correct += 1 }
                }
            }
            return correct
        }

        #expect(try correctCells(detail: 2) == rows * rows, "detail 2 must get every cell right")
        let flat = try correctCells(detail: 1)
        #expect(flat < rows * rows, "detail 1 cannot tell them apart, it got \(flat)")
    }

    // MARK: - Determinism

    @Test("the same seed gives the same mosaic, and different seeds do not")
    func determinism() throws {
        let pool = latticePool(perAxis: 5)
        let target = uniformTarget(rows: 12, colour: LinearRGB(r: 0.5, g: 0.5, b: 0.5))

        func solve(seed: UInt64) throws -> MosaicLayout {
            try MosaicSolver.solve(
                target: target, subject: PhotoID("C"), previousSubject: pool[3].id,
                pool: pool, options: SolverOptions(repetitionSpacing: 2), seed: seed
            ).layout
        }

        #expect(try solve(seed: 99) == (try solve(seed: 99)))
        #expect(try solve(seed: 99) != (try solve(seed: 100)))
    }

    @Test("permuting the pool changes nothing, so ties are not decided by position")
    func poolOrderIndependence() throws {
        let pool = latticePool(perAxis: 5)
        var rng = SplitMix64(seed: 61)
        let shuffled = rng.shuffled(pool)
        let target = randomTarget(rows: 10, seed: 55)

        func solve(_ pool: [PoolEntry]) throws -> MosaicLayout {
            try MosaicSolver.solve(
                target: target, subject: PhotoID("C"), previousSubject: nil,
                pool: pool, options: unconstrained, seed: 12
            ).layout
        }

        #expect(try solve(pool) == (try solve(shuffled)))
    }

    // MARK: - Degenerate inputs

    @Test("degenerate pools and grids terminate instead of looping or crashing")
    func degenerateInputs() throws {
        let single = [PoolEntry(id: PhotoID("only"), signature: TileSignature(mean: .white))]
        let onlyLayout = try MosaicSolver.solve(
            target: randomTarget(rows: 2), subject: PhotoID("C"), previousSubject: PhotoID("only"),
            pool: single, options: SolverOptions(repetitionSpacing: 0), seed: 1
        ).layout
        #expect(onlyLayout.tiles.allSatisfy { $0.photo == PhotoID("only") })

        // A spacing wider than the grid is clamped rather than rejected.
        let pool = latticePool(perAxis: 4)
        let wide = try MosaicSolver.solve(
            target: randomTarget(rows: 3), subject: PhotoID("C"), previousSubject: nil,
            pool: pool, options: SolverOptions(repetitionSpacing: 50), seed: 1
        ).layout
        #expect(wide.tiles.count == 9)
        #expect(Set(wide.tiles.map(\.photo)).count == 9, "everything visible must differ")

        #expect(throws: MosaicSolverError.self) {
            _ = try MosaicSolver.solve(
                target: randomTarget(rows: 4), subject: PhotoID("C"), previousSubject: nil,
                pool: [], options: SolverOptions(), seed: 1
            )
        }

        #expect(throws: MosaicSolverError.self) {
            _ = try MosaicSolver.solve(
                target: randomTarget(rows: 4, detail: 1), subject: PhotoID("C"), previousSubject: nil,
                pool: pool, options: SolverOptions(detail: 2), seed: 1
            )
        }
    }
}
