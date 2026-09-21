import Foundation
import MosaicCore

/// Which photograph each cycle depicts, as a function of the cycle number.
///
/// The one rule it enforces is that consecutive cycles differ. B and C being the
/// same photograph would put C inside its own mosaic and make a whole cycle of
/// zooming look like it went nowhere.
///
/// Getting that right is fiddlier than it looks, and the obvious version is
/// wrong: comparing a cycle's draw against the *draw* of the one before is not
/// the same as comparing it against the *subject* of the one before, because
/// that cycle may itself have been moved off its draw. The comparison has to be
/// against the resolved answer, which makes it a recurrence.
///
/// The recurrence is walked back a bounded number of steps rather than to cycle
/// zero, because a cycle index can be large — the harness jumps by cycles — and
/// the chain only continues while consecutive draws keep colliding, which has
/// probability `1/count` each time. Sixteen is past the point where the
/// remaining risk is worth a line of code, and its only consequence would be one
/// cycle that repeats a photograph.
struct SubjectSequence: Sendable {
    let count: Int
    let seed: UInt64

    static let maximumChain = 16

    init(count: Int, seed: UInt64) {
        precondition(count > 0, "a cycle needs a photograph to show")
        self.count = count
        self.seed = seed
    }

    func index(ofCycle cycle: Int) -> Int {
        resolve(cycle, depth: Self.maximumChain)
    }

    private func draw(_ cycle: Int) -> Int {
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9)
        return rng.next(upperBound: count)
    }

    private func resolve(_ cycle: Int, depth: Int) -> Int {
        let raw = draw(cycle)
        guard count > 1, cycle > 0, depth > 0 else { return raw }
        let previous = resolve(cycle - 1, depth: depth - 1)
        guard raw == previous else { return raw }
        // Step to any of the others, deterministically.
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: Int64(cycle)) &* 0x5BF0_3635)
        return (previous + 1 + rng.next(upperBound: count - 1)) % count
    }
}
