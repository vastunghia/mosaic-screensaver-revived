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
