import Foundation
import MosaicCore

/// Which photograph each cycle depicts, as a function of the cycle number.
///
/// Two rules, both SPEC § 5:
///
/// - **A deck, not a die.** The pool is shuffled, and every photograph is
///   shown once before any is shown again. Independent draws repeat long before
///   they run out: with 2048 photographs, twenty cycles already have one chance
///   in ten of showing a subject twice, and a real batch did.
/// - **The next subject is one the last can sit in.** Cycle `n` zooms out of
///   B, and B has to take a cell of the new mosaic. Drawn blind, the new
///   subject may have no region of B's colour, and B then sits in the mosaic
///   like a wrong tile: on twenty real subjects the anchor cost between 1 and
///   20 delta E. So each cycle looks at the next few photographs of the deck
///   and takes the one with a region closest to B's colour.
///
/// The window slides: a photograph passed over stays at the front of what is
/// left and is a candidate again next cycle, so none is starved, and the one
/// that fits nothing is taken when the deck runs short.
///
/// The fit is judged on the index signatures, not on target grids: a 4×4
/// signature is sixteen region colours already in memory, where a grid would
/// mean decoding a thumbnail per candidate per cycle. It is coarser than the
/// cells B can actually land in, so it underestimates how well B can fit, and
/// never the reverse.
///
/// The price is a sequence that depends on its own past, so a cycle's subject
/// cannot be computed without the ones before it. They are computed once, in
/// order, and remembered: a few integers per cycle, microseconds each.
final class SubjectSequence: @unchecked Sendable {
    let count: Int
    let seed: UInt64

    /// How many photographs of the deck each cycle chooses among. 1 is a plain
    /// shuffled deck.
    let candidates: Int

    /// Per photograph, its mean colour and its region colours, in Lab. Empty
    /// when there are no signatures, which makes the sequence a plain deck.
    private let means: [LabColor]
    private let regions: [[LabColor]]

    private let lock = NSLock()
    private var history: [Int] = []
    private var remaining: [Int] = []
    private var epoch = -1

    static let defaultCandidates = 8

    init(count: Int, seed: UInt64, signatures: [TileSignature] = [], candidates: Int = SubjectSequence.defaultCandidates) {
        precondition(count > 0, "a cycle needs a photograph to show")
        precondition(signatures.isEmpty || signatures.count == count, "one signature per photograph, or none")
        precondition(candidates >= 1, "a cycle has to choose among at least one photograph")
        self.count = count
        self.seed = seed
        self.candidates = signatures.isEmpty ? 1 : candidates
        means = signatures.map { LabColor($0.mean) }
        regions = signatures.map { $0.cells.map(LabColor.init) }
    }

    func index(ofCycle cycle: Int) -> Int {
        precondition(cycle >= 0, "cycles are numbered from zero")
        lock.lock(); defer { lock.unlock() }
        while history.count <= cycle { history.append(next()) }
        return history[cycle]
    }

    /// How far B's colour is from the closest region of `candidate`.
    func fit(of previous: Int, in candidate: Int) -> Double {
        guard !means.isEmpty else { return 0 }
        let colour = means[previous]
        return regions[candidate].map { $0.squaredDeltaE(to: colour) }.min()!.squareRoot()
    }

    private func next() -> Int {
        let previous = history.last
        if remaining.isEmpty {
            epoch += 1
            remaining = shuffledDeck(epoch)
        }

        // Never the photograph just shown. Only possible across a reshuffle,
        // where the new deck may start with the old deck's last card.
        let window = Array(remaining.prefix(candidates + 1)).filter { $0 != previous || count == 1 }
        var choice = window.first!
        if let previous, window.count > 1 {
            let options = window.prefix(candidates)
            choice = options.min { fit(of: previous, in: $0) < fit(of: previous, in: $1) }!
        }
        remaining.remove(at: remaining.firstIndex(of: choice)!)
        return choice
    }

    private func shuffledDeck(_ epoch: Int) -> [Int] {
        var rng = SplitMix64(seed: seed &+ UInt64(epoch + 1) &* 0x9E37_79B9_7F4A_7C15)
        var deck = Array(0..<count)
        if count > 1 {
            for index in stride(from: count - 1, to: 0, by: -1) {
                deck.swapAt(index, rng.next(upperBound: index + 1))
            }
        }
        return deck
    }
}
