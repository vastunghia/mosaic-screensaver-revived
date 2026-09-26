import MosaicCore

/// The knobs that change what a mosaic looks like.
///
/// They are options rather than constants because milestone 2 exists to settle
/// them by looking at exports, and a number settled that way should arrive with
/// the evidence rather than ahead of it.
public struct SolverOptions: Equatable, Sendable {
    /// `k`: how finely a tile is compared to a cell. 1 is the average colour of
    /// SPEC § 5 step 3; 2 and 4 also ask the tile to have the right structure.
    public var detail: Int

    /// How the three Lab axes are weighted against each other.
    public var weights: LabWeights

    /// The minimum Chebyshev distance, in cells, between two uses of the same
    /// photograph — SPEC § 5, "Pool e ripetizioni". 0 disables it.
    public var repetitionSpacing: Int

    /// What each previous use of a photograph adds to its score, in delta E.
    ///
    /// Spacing alone is not enough, and this is the difference that shows. A
    /// greedy nearest match on a blue sky draws from the twenty bluest
    /// photographs and nothing else: at `R` = 90 with a spacing of 6, one
    /// photograph may still legally hold 169 cells, and the mosaic reads as
    /// thirty pictures. The penalty is what spreads it out; `maximumUses` is
    /// only the backstop behind it.
    public var repetitionPenalty: Double

    /// A hard cap on how many cells one photograph may hold. `nil` derives one
    /// from the pool size with room to spare, or, with a tolerance, sets none.
    public var maximumUses: Int?

    /// The delta E a tile may be off by and still count as a match. When set,
    /// it replaces the penalty: each cell takes the least used photograph
    /// within the tolerance, and the closest of those.
    ///
    /// The penalty puts one price on a repetition for every cell of every
    /// subject, and no single price suits both a meadow and a night sky: high
    /// enough to vary the one, it wrecks the other. A tolerance lets the price
    /// follow the corpus instead. Where many photographs are close enough, the
    /// uses spread thin; where only a few dark ones are, those few take the
    /// whole sky between them. It is also a per-cell quantity, so it means the
    /// same at every `R` and every pool size, where a cap and a penalty do not.
    ///
    /// A cell no photograph gets within the tolerance of is widened to its
    /// nearest candidate plus `toleranceSlack`, so that one colour the corpus
    /// lacks is still shared among a few photographs rather than handed to one.
    public var tolerance: Double?

    public init(
        detail: Int = 1,
        weights: LabWeights = .neutral,
        repetitionSpacing: Int = 3,
        repetitionPenalty: Double = 1,
        maximumUses: Int? = nil,
        tolerance: Double? = nil
    ) {
        precondition(detail >= 1 && detail & (detail - 1) == 0, "detail has to be a power of two")
        precondition(repetitionSpacing >= 0, "a spacing cannot be negative")
        precondition(repetitionPenalty >= 0, "a penalty cannot be negative")
        precondition(tolerance.map { $0 >= 0 } ?? true, "a tolerance cannot be negative")
        self.detail = detail
        self.weights = weights
        self.repetitionSpacing = repetitionSpacing
        self.repetitionPenalty = repetitionPenalty
        self.maximumUses = maximumUses
        self.tolerance = tolerance
    }

    /// The settings SPEC § 5 decided, by looking at twenty subjects of a real
    /// 2048-photograph corpus side by side (2026-09-26). The initialiser's own
    /// defaults are the plain mechanism, for tests; this is what a mosaic uses.
    ///
    /// - `k` = 4: clearly better than 1, and 8 was not visibly better than 4
    ///   for four times the solve.
    /// - Tolerance 16: chosen at `k` = 4, and only meaningful there. The
    ///   distance is a root mean square over `k²` sub-cells, which grows with
    ///   `k`: at `k` = 4 a tolerance of 8 and one of 12 give the same mosaic.
    ///   Change `k` and the tolerance has to be chosen again.
    /// - Spacing 3, confirmed on the same corpus.
    public static let standard = SolverOptions(detail: 4, repetitionSpacing: 3, tolerance: 16)

    /// How far past the nearest candidate a cell's band reaches when nothing
    /// is within the tolerance. A guess, about one just noticeable difference
    /// on a flat colour; it only matters for colours the corpus lacks.
    static let toleranceSlack = 2.0

    /// How much slack the derived cap leaves above a perfectly even share. The
    /// penalty is meant to do the spreading; the cap only stops the tail.
    static let derivedUsageSlack = 4

    func resolvedMaximumUses(cellCount: Int, poolCount: Int) -> Int {
        if let maximumUses { return max(1, maximumUses) }
        // With a tolerance the repetitions are meant to follow the corpus, and
        // a derived cap would put back exactly the limit it replaces.
        if tolerance != nil { return .max }
        let evenShare = (cellCount + poolCount - 1) / poolCount
        return max(1, evenShare * Self.derivedUsageSlack)
    }
}
