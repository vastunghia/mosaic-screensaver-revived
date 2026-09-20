import Foundation

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
