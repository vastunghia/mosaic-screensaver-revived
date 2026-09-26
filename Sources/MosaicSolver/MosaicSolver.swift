import Foundation
import MosaicCore

/// M3: builds the mosaic for one cycle (SPEC § 5).
///
/// Pure, and deliberately so: given the same target, pool, options and seed it
/// returns the same mosaic in any process, on any machine, in the app and in the
/// .saver alike. That is not tidiness. The app and the saver share an index but
/// not their code paths, and a mosaic that differed between them would surface
/// at milestone 5 as "the saver looks worse", with no visible cause.
///
/// Two consequences of that promise are load-bearing and easy to break:
///
/// - **Nothing here iterates a `Set` or a `Dictionary`.** Their order is
///   randomised per process, so iterating one would make two runs disagree.
///   Membership tests are safe; the forbidden neighbours are therefore a marker
///   array, which is also faster.
/// - **Nothing here touches a `PhotoID` inside a loop.** Identifiers are mapped
///   to integers up front and back at the end. Hashing strings twenty million
///   times is the difference between 0.1 s and 10 s.
public enum MosaicSolver {
    /// - Parameters:
    ///   - target: the photograph this mosaic depicts, sampled on the mosaic's
    ///     own grid at `options.detail`.
    ///   - previousSubject: the photograph of the cycle before, which must end up
    ///     in the anchor cell — SPEC § 5 step 4.
    ///   - seed: makes the cycle reproducible, which is what lets the harness
    ///     scrub backwards and see the same thing twice.
    public static func solve(
        target: TargetGrid,
        subject: PhotoID,
        previousSubject: PhotoID?,
        pool: [PoolEntry],
        options: SolverOptions = SolverOptions(),
        seed: UInt64
    ) throws -> SolveResult {
        guard !pool.isEmpty else { throw MosaicSolverError.emptyPool }
        guard target.detail == options.detail else {
            throw MosaicSolverError.detailMismatch(target: target.detail, options: options.detail)
        }

        let rows = target.rows
        let cellCount = rows * rows
        let detail = options.detail
        let block = detail * detail
        let spacing = min(options.repetitionSpacing, rows - 1)

        // The one precondition that replaces a per-cell fallback: if the pool is
        // bigger than the neighbourhood a spacing forbids, there is always at
        // least one legal candidate, so the inner loop needs no relaxation path.
        let forbiddenAtMost = (2 * spacing + 1) * (2 * spacing + 1) - 1
        guard pool.count > forbiddenAtMost else {
            throw MosaicSolverError.poolTooSmallForSpacing(pool: pool.count, needed: forbiddenAtMost)
        }

        // MARK: - Flatten everything to Doubles and integers

        var poolLab = [Double](repeating: 0, count: pool.count * block * 3)
        var poolMean = [LabColor](repeating: LabColor(l: 0, a: 0, b: 0), count: pool.count)
        for (index, entry) in pool.enumerated() {
            guard entry.signature.side >= detail else {
                throw MosaicSolverError.signatureTooCoarse(
                    photo: entry.id, side: entry.signature.side, needed: detail
                )
            }
            let reduced = entry.signature.reduced(to: detail)
            for (cell, colour) in reduced.cells.enumerated() {
                let lab = LabColor(colour)
                let base = (index * block + cell) * 3
                poolLab[base] = lab.l
                poolLab[base + 1] = lab.a
                poolLab[base + 2] = lab.b
            }
            poolMean[index] = LabColor(entry.signature.mean)
        }

        var targetLab = [Double](repeating: 0, count: cellCount * block * 3)
        var cellMean = [LabColor](repeating: LabColor(l: 0, a: 0, b: 0), count: cellCount)
        for row in 0..<rows {
            for column in 0..<rows {
                let cell = GridCell(column: column, row: row)
                let signature = target.signature(of: cell)
                let index = row * rows + column
                for (subCell, colour) in signature.cells.enumerated() {
                    let lab = LabColor(colour)
                    let base = (index * block + subCell) * 3
                    targetLab[base] = lab.l
                    targetLab[base + 1] = lab.a
                    targetLab[base + 2] = lab.b
                }
                cellMean[index] = LabColor(signature.mean)
            }
        }

        var rng = SplitMix64(seed: seed)

        // MARK: - The anchor (SPEC § 5 step 4)

        let previousIndex = previousSubject.flatMap { photo in
            pool.firstIndex { $0.id == photo }
        }

        // B occupies the anchor cell and nowhere else: a second flat copy of the
        // photograph the viewer has just zoomed out of reads as a mistake. It is
        // barred from every other cell unless it is all there is.
        let barred = pool.count > 1 ? previousIndex : nil
        if barred != nil {
            guard pool.count > forbiddenAtMost + 1 else {
                throw MosaicSolverError.poolTooSmallForSpacing(
                    pool: pool.count, needed: forbiddenAtMost + 1
                )
            }
        }

        var anchorIndex: Int
        var anchorDeltaE = 0.0
        if let previousIndex {
            let wanted = poolMean[previousIndex]
            // Ties are broken with the seed, not by taking the first. On a flat
            // target — a sky, a wall — thousands of cells tie, and argmin would
            // put the anchor in the top-left corner on every single cycle, which
            // is extremely visible.
            var best = Double.infinity
            var ties = 0
            var chosen = 0
            for index in 0..<cellCount {
                let distance = cellMean[index].squaredDeltaE(to: wanted, weights: options.weights)
                if distance < best - 1e-12 {
                    best = distance
                    chosen = index
                    ties = 1
                } else if distance <= best + 1e-12 {
                    ties += 1
                    if rng.next(upperBound: ties) == 0 { chosen = index }
                }
            }
            anchorIndex = chosen
            anchorDeltaE = best.squareRoot()
        } else {
            // The very first cycle has no photograph to come from; the anchor
            // only says where the camera starts.
            anchorIndex = rng.next(upperBound: cellCount)
        }

        // MARK: - Fill

        var assigned = [Int](repeating: -1, count: cellCount)
        var uses = [Int](repeating: 0, count: pool.count)
        var isForbidden = [Bool](repeating: false, count: pool.count)

        if let previousIndex {
            assigned[anchorIndex] = previousIndex
            uses[previousIndex] += 1
        }

        // Raster order would make the same cells pay for the spacing constraint
        // every time, and that shows up as a drift across the picture.
        let order = rng.shuffled((0..<cellCount).filter { assigned[$0] < 0 })

        let maximumUses = options.resolvedMaximumUses(cellCount: cellCount, poolCount: pool.count)
        let lightnessSquared = options.weights.lightness * options.weights.lightness
        let chromaSquared = options.weights.chroma * options.weights.chroma
        let penalty = options.repetitionPenalty
        let inverseBlock = 1 / Double(block)
        let tolerance = options.tolerance
        var distances = [Double](repeating: .infinity, count: tolerance == nil ? 0 : pool.count)

        poolLab.withUnsafeBufferPointer { poolBuffer in
            targetLab.withUnsafeBufferPointer { targetBuffer in
                for cellIndex in order {
                    let row = cellIndex / rows
                    let column = cellIndex % rows

                    var marked: [Int] = []
                    if spacing > 0 {
                        marked.reserveCapacity(forbiddenAtMost)
                        for y in max(0, row - spacing)...min(rows - 1, row + spacing) {
                            for x in max(0, column - spacing)...min(rows - 1, column + spacing) {
                                let neighbour = assigned[y * rows + x]
                                if neighbour >= 0, !isForbidden[neighbour] {
                                    isForbidden[neighbour] = true
                                    marked.append(neighbour)
                                }
                            }
                        }
                    }

                    let targetBase = cellIndex * block * 3
                    var bestScore = Double.infinity
                    var bestIndex = -1
                    var spareScore = Double.infinity
                    var spareIndex = -1

                    for candidate in 0..<pool.count {
                        if isForbidden[candidate] || candidate == barred {
                            if tolerance != nil { distances[candidate] = .infinity }
                            continue
                        }

                        var total = 0.0
                        var poolOffset = candidate * block * 3
                        var targetOffset = targetBase
                        for _ in 0..<block {
                            let dl = poolBuffer[poolOffset] - targetBuffer[targetOffset]
                            let da = poolBuffer[poolOffset + 1] - targetBuffer[targetOffset + 1]
                            let db = poolBuffer[poolOffset + 2] - targetBuffer[targetOffset + 2]
                            total += dl * dl * lightnessSquared
                                + (da * da + db * db) * chromaSquared
                            poolOffset += 3
                            targetOffset += 3
                        }

                        // Root mean square over the sub-cells, so detail 1 is
                        // exactly the plain delta E of the average colour and
                        // the number means the same thing at every detail.
                        let distance = (total * inverseBlock).squareRoot()
                        if tolerance != nil {
                            // Chosen in a second pass, once the nearest is known.
                            distances[candidate] = distance
                            if distance < spareScore {
                                spareScore = distance
                                spareIndex = candidate
                            }
                            continue
                        }
                        let score = distance + penalty * Double(uses[candidate])

                        if score < spareScore {
                            spareScore = score
                            spareIndex = candidate
                        }
                        if uses[candidate] < maximumUses, score < bestScore {
                            bestScore = score
                            bestIndex = candidate
                        }
                    }

                    if let tolerance {
                        // Least used within the band, then closest. Outside the
                        // band, or when the band is all at its cap, the closest
                        // photograph still under the cap.
                        let band = max(tolerance, spareScore + SolverOptions.toleranceSlack)
                        var bestUses = Int.max
                        var bestDistance = Double.infinity
                        var fallbackDistance = Double.infinity
                        var fallbackIndex = -1
                        for candidate in 0..<pool.count {
                            let distance = distances[candidate]
                            let used = uses[candidate]
                            if distance == .infinity || used >= maximumUses { continue }
                            if distance <= band {
                                if used < bestUses || (used == bestUses && distance < bestDistance) {
                                    bestUses = used
                                    bestDistance = distance
                                    bestIndex = candidate
                                }
                            } else if distance < fallbackDistance {
                                fallbackDistance = distance
                                fallbackIndex = candidate
                            }
                        }
                        if bestIndex < 0 { bestIndex = fallbackIndex }
                    }

                    // spareIndex is always set: the precondition above says the
                    // pool outnumbers the forbidden neighbourhood. bestIndex can
                    // be empty only if every legal candidate is at its cap, and
                    // then the cap gives way rather than the spacing.
                    let chosen = bestIndex >= 0 ? bestIndex : spareIndex
                    assigned[cellIndex] = chosen
                    uses[chosen] += 1

                    for neighbour in marked { isForbidden[neighbour] = false }
                }
            }
        }

        // MARK: - Layout and statistics

        var tiles = assigned.map { TileAssignment(photo: pool[$0].id) }
        if let previousSubject {
            // Belt and braces: if B were somehow not in the pool it still has to
            // sit in the anchor cell, because CycleEngine.frame asserts on it.
            tiles[anchorIndex] = TileAssignment(photo: previousSubject)
        }

        let layout = MosaicLayout(
            rows: rows,
            subject: subject,
            anchor: GridCell(column: anchorIndex % rows, row: anchorIndex / rows),
            tiles: tiles
        )

        var cellDeltaE = [Double](repeating: 0, count: cellCount)
        var sumOfSquares = 0.0
        var worst = 0.0
        for index in 0..<cellCount {
            let distance = cellMean[index].deltaE(to: poolMean[assigned[index]], weights: options.weights)
            cellDeltaE[index] = distance
            sumOfSquares += distance * distance
            worst = max(worst, distance)
        }

        let statistics = SolveStatistics(
            rootMeanSquareDeltaE: (sumOfSquares / Double(cellCount)).squareRoot(),
            maximumDeltaE: worst,
            distinctPhotos: uses.reduce(0) { $0 + ($1 > 0 ? 1 : 0) },
            maximumUses: uses.max() ?? 0,
            anchorDeltaE: anchorDeltaE,
            cellCount: cellCount,
            cellDeltaE: cellDeltaE,
            photoUses: uses
        )

        return SolveResult(layout: layout, statistics: statistics)
    }
}
