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
    /// from the pool size with room to spare.
    public var maximumUses: Int?

    public init(
        detail: Int = 1,
        weights: LabWeights = .neutral,
        repetitionSpacing: Int = 3,
        repetitionPenalty: Double = 2,
        maximumUses: Int? = nil
    ) {
        precondition(detail >= 1 && detail & (detail - 1) == 0, "detail has to be a power of two")
        precondition(repetitionSpacing >= 0, "a spacing cannot be negative")
        precondition(repetitionPenalty >= 0, "a penalty cannot be negative")
        self.detail = detail
        self.weights = weights
        self.repetitionSpacing = repetitionSpacing
        self.repetitionPenalty = repetitionPenalty
        self.maximumUses = maximumUses
    }

    /// How much slack the derived cap leaves above a perfectly even share. The
    /// penalty is meant to do the spreading; the cap only stops the tail.
    static let derivedUsageSlack = 4

    func resolvedMaximumUses(cellCount: Int, poolCount: Int) -> Int {
        if let maximumUses { return max(1, maximumUses) }
        let evenShare = (cellCount + poolCount - 1) / poolCount
        return max(1, evenShare * Self.derivedUsageSlack)
    }
}
