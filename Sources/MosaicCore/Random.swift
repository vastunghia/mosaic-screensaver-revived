import Foundation

/// The project's one source of reproducible randomness.
///
/// It lives in MosaicCore, and not wherever it happens to be needed, because
/// determinism is a contract rather than a convenience: the app and the .saver
/// have to build the same mosaic from the same seed, and the harness has to be
/// able to scrub backwards and see the same frame twice.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<upperBound`, without the modulo bias that `% n` has.
    public mutating func next(upperBound: Int) -> Int {
        precondition(upperBound > 0, "an upper bound has to be positive")
        let bound = UInt64(upperBound)
        let limit = UInt64.max - (UInt64.max % bound)
        var draw = next()
        while draw >= limit { draw = next() }
        return Int(draw % bound)
    }

    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A seeded shuffle, used wherever visiting things in their natural order
    /// would show up as a pattern on screen.
    public mutating func shuffled<T>(_ items: [T]) -> [T] {
        var result = items
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            result.swapAt(index, next(upperBound: index + 1))
        }
        return result
    }
}
