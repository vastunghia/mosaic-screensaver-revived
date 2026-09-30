import Foundation
import MosaicSolver

/// What the last few frames cost.
///
/// Every number here is meaningless without the name of the GPU that produced
/// it: this machine has a Radeon Pro 560X and an RX 6800 on Thunderbolt, and a
/// frame time quoted without saying which one it came from is not a measurement.
/// Hence `deviceName` sitting in the same struct as the timings.
public struct FrameStatistics: Sendable {
    public var deviceName: String = ""
    public var gpuMilliseconds: Double = 0
    public var tileCount: Int = 0
    public var cycleIndex: Int = 0
    public var u: Double = 0

    /// Which photograph the current mosaic depicts. Comparing two solver
    /// settings is meaningless unless it is the same photograph both times.
    public var subject: String = ""

    /// How the last mosaic scored. Milestone 2's deliverable is a judgement, and
    /// this is what turns "that one looks worse" into "that one is worse".
    public var solve: SolveStatistics?

    /// How many times a mosaic needed on screen was not ready and had to be
    /// built on the render thread. The first cycle, a scrub and a change of R
    /// account for some; in steady state it must not move.
    public var stalls: Int = 0

    /// Close-ups asked for and not ready when their cycle began, so the tile
    /// stayed an atlas slice for that whole cycle. Must not move once running.
    public var closeUpMisses: Int = 0

    /// GPU memory held by close-ups, mip pyramids included.
    public var closeUpBytes: Int = 0

    /// Times the engine rebuilt itself on a GPU, and how long the last one took
    /// — the gap on screen when an eGPU is unplugged.
    public var rebuilds: Int = 0
    public var lastRebuildSeconds: Double = 0

    /// Stretches of more than `MosaicEngine.freezeThreshold` in which the
    /// effect stood still when it should have moved. Each is in the log.
    public var freezes: Int = 0

    /// Why the last mosaic fell back to random tiles, if it did.
    public var lastError: String?

    public init() {}
}

final class StatisticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FrameStatistics()

    var current: FrameStatistics {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ change: (inout FrameStatistics) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&value)
    }
}
