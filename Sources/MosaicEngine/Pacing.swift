import Darwin
import Foundation

/// A stretch during which the effect stood still on screen when it should have
/// been moving, and what was going on meanwhile.
///
/// The effect is meant to run unattended for hours, and a freeze of two or
/// three seconds in the middle of a zoom is exactly the kind of thing nobody is
/// watching for when it happens. So the engine watches itself: every frame it
/// compares how much real time has passed with how much animation time has,
/// and a gap past `Pacing.threshold` becomes one of these, logged with the
/// evidence needed to tell the possible causes apart.
public struct Freeze: Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The engine was asked whether it was ready and said no: the host held
        /// its clock. `notReady` says why.
        case held
        /// The host kept calling but frames were not presented: no drawable, or
        /// the previous frame never came back from the GPU.
        case unpresented
        /// Frames were presented, but getting a drawable or a free frame slot
        /// took most of the gap: the GPU or the compositor was behind.
        case gpu
        /// Nobody called the engine at all for most of the gap: the host's
        /// thread was busy elsewhere, or its display link did not fire.
        case stopped
    }

    public var kind: Kind
    /// On the `ProcessInfo.systemUptime` clock, which is the one the
    /// background activities below are timed on too.
    public var start: TimeInterval
    public var duration: TimeInterval
    public var cycleIndex: Int
    public var u: Double
    /// Animation time that passed across the gap. The host caps each step, so
    /// after a long freeze this is small and the effect picks up where it was.
    public var animationStep: TimeInterval

    public var framesPresented: Int
    public var framesNotPresented: Int
    public var longestSilence: TimeInterval
    public var notReady: [String: Int]
    public var slowestDrawableWait: TimeInterval
    public var slowestInFlightWait: TimeInterval
    public var slowestFrame: TimeInterval

    /// Background work that overlapped the gap, one line each, timed from its
    /// start.
    public var activities: [String]
    public var system: SystemLoad.Change

    public var description: String {
        var parts = [
            String(format: "freeze %.2f s (%@) at cycle %d u=%.3f", duration, kind.rawValue, cycleIndex, u),
            String(format: "then +%.3f s of animation", animationStep),
            "\(framesPresented) frames presented, \(framesNotPresented) not",
            String(format: "longest silence %.2f s", longestSilence),
            String(format: "slowest frame %.3f s (drawable %.3f, in flight %.3f)",
                   slowestFrame, slowestDrawableWait, slowestInFlightWait),
        ]
        if !notReady.isEmpty {
            parts.append("not ready: " + notReady.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        parts.append(system.description)
        parts.append(activities.isEmpty ? "no background work" : "background: " + activities.joined(separator: "; "))
        return parts.joined(separator: " · ")
    }
}

/// The frame-by-frame bookkeeping behind `Freeze`, kept apart from Metal so it
/// can be tested with made-up timestamps.
///
/// A *moving* frame is one that was presented with a different animation time
/// from the last moving frame. Between two moving frames the tracker tallies
/// everything the host did, and hands the tally over as a `Gap` when the next
/// moving frame arrives. Every frame produces one, most of them a sixtieth of a
/// second long; the engine decides which ones matter.
struct PacingTracker {
    struct Tally {
        var calls = 0
        var staticFrames = 0
        var unpresented = 0
        var longestSilence: TimeInterval = 0
        var notReady: [String: Int] = [:]
        var slowestDrawableWait: TimeInterval = 0
        var slowestInFlightWait: TimeInterval = 0
        var slowestFrame: TimeInterval = 0
    }

    struct Gap {
        let start: TimeInterval
        let duration: TimeInterval
        let animationStart: TimeInterval
        let animationStep: TimeInterval
        let tally: Tally

        /// What kept the effect still, in the order the evidence is strongest.
        /// Nil when nothing did: the host simply did not move its clock, which
        /// is a pause and not a freeze.
        func kind(threshold: TimeInterval) -> Freeze.Kind? {
            if !tally.notReady.isEmpty { return .held }
            if tally.unpresented > 0 { return .unpresented }
            if max(tally.slowestDrawableWait, tally.slowestInFlightWait) >= threshold / 2 { return .gpu }
            if tally.longestSilence >= threshold || tally.staticFrames == 0 { return .stopped }
            return nil
        }
    }

    struct Frame {
        var wall: TimeInterval
        var time: TimeInterval
        var presented: Bool
        var drawableWait: TimeInterval = 0
        var inFlightWait: TimeInterval = 0
        var duration: TimeInterval = 0
    }

    private var lastMoving: (wall: TimeInterval, time: TimeInterval)?
    private var lastCall: TimeInterval?
    private var tally = Tally()

    /// Any call from the host: the silences between them are what tells a host
    /// that stopped calling from an engine that was not ready.
    mutating func call(at wall: TimeInterval) {
        if let lastCall { tally.longestSilence = max(tally.longestSilence, wall - lastCall) }
        lastCall = wall
        tally.calls += 1
    }

    mutating func notReady(_ reason: String, at wall: TimeInterval) {
        call(at: wall)
        tally.notReady[reason, default: 0] += 1
    }

    mutating func frame(_ frame: Frame) -> Gap? {
        call(at: frame.wall)
        tally.slowestDrawableWait = max(tally.slowestDrawableWait, frame.drawableWait)
        tally.slowestInFlightWait = max(tally.slowestInFlightWait, frame.inFlightWait)
        tally.slowestFrame = max(tally.slowestFrame, frame.duration)
        guard frame.presented else {
            tally.unpresented += 1
            return nil
        }
        guard let last = lastMoving else {
            lastMoving = (frame.wall, frame.time)
            tally = Tally()
            return nil
        }
        guard frame.time != last.time else {
            tally.staticFrames += 1
            return nil
        }
        let gap = Gap(
            start: last.wall,
            duration: frame.wall - last.wall,
            animationStart: last.time,
            animationStep: frame.time - last.time,
            tally: tally
        )
        lastMoving = (frame.wall, frame.time)
        tally = Tally()
        return gap
    }
}

/// How smoothly one cycle ran, for a line in the log at its end.
///
/// Besides the totals, the cycle is cut in `CyclePacing.binCount` stretches
/// of `u`: a stutter of single missed refreshes, too short to be a freeze,
/// shows up as frames missed in some stretches and not others, next to what
/// the GPU and the compositor were doing there.
struct CyclePacing {
    static let binCount = 10

    struct Bin {
        var frames = 0
        /// Gaps past one and a half refreshes at 60 Hz: at least one refresh
        /// showed the same frame twice.
        var missed = 0
        var drawableWaitTotal: TimeInterval = 0
        var drawableWaitMax: TimeInterval = 0
        var frameMax: TimeInterval = 0
        var tilesMax = 0
    }

    var frames = 0
    var over50 = 0
    var over100 = 0
    var worst: TimeInterval = 0
    var worstU: Double = 0
    var freezes = 0
    var bins = [Bin](repeating: Bin(), count: binCount)
    var wallStart: TimeInterval?
    var wallEnd: TimeInterval = 0

    static func bin(_ u: Double) -> Int { min(max(Int(u * Double(binCount)), 0), binCount - 1) }

    mutating func add(_ gap: TimeInterval, u: Double) {
        frames += 1
        if gap > 0.05 { over50 += 1 }
        if gap > 0.1 { over100 += 1 }
        if gap > worst {
            worst = gap
            worstU = u
        }
        if gap > 1.5 / 60 { bins[Self.bin(u)].missed += 1 }
    }

    /// Every frame drawn, moving or not.
    mutating func drew(_ frame: PacingTracker.Frame, u: Double, tiles: Int) {
        if wallStart == nil { wallStart = frame.wall }
        wallEnd = frame.wall
        var bin = bins[Self.bin(u)]
        bin.frames += 1
        bin.drawableWaitTotal += frame.drawableWait
        bin.drawableWaitMax = max(bin.drawableWaitMax, frame.drawableWait)
        bin.frameMax = max(bin.frameMax, frame.duration)
        bin.tilesMax = max(bin.tilesMax, tiles)
        bins[Self.bin(u)] = bin
    }
}

/// GPU time of each frame, by stretch of `u`. Written from Metal's completion
/// handlers, read by the host's thread at the end of a cycle.
final class GPUTimings: @unchecked Sendable {
    struct Bin {
        var frames = 0
        var total: TimeInterval = 0
        var max: TimeInterval = 0
        /// Longer than a refresh at 60 Hz: that frame alone cannot keep up.
        var overRefresh = 0
    }

    /// When frames reached the glass, from each drawable's presented handler:
    /// the only measure of what a viewer sees. Timing the calls to `advance`
    /// is not — on the iMac's display they came 4 and 29 ms apart in turn at
    /// a steady 60 fps shown.
    struct Shown {
        var frames = 0
        /// Presented more than one and a half refreshes after the frame before:
        /// the one before stayed on screen for an extra refresh at least.
        var late = 0
        /// Never presented: the compositor dropped it for a newer one.
        var dropped = 0
        var longest: TimeInterval = 0
    }

    private let lock = NSLock()
    private var bins: [Int: [Bin]] = [:]
    private var shown: [Int: [Shown]] = [:]
    private var lastPresented: CFTimeInterval = 0
    /// When recent frames reached the screen, oldest first, for a few seconds.
    private var recentPresentations: [CFTimeInterval] = []
    private static let recentSpan: CFTimeInterval = 10

    func presented(cycle: Int, bin: Int, at time: CFTimeInterval, refresh: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        var cycleBins = shown[cycle] ?? [Shown](repeating: Shown(), count: CyclePacing.binCount)
        if time == 0 {
            cycleBins[bin].dropped += 1
        } else {
            cycleBins[bin].frames += 1
            if lastPresented > 0, time > lastPresented {
                let interval = time - lastPresented
                if interval > 1.5 * refresh { cycleBins[bin].late += 1 }
                cycleBins[bin].longest = Swift.max(cycleBins[bin].longest, interval)
            }
            lastPresented = time
            recentPresentations.append(time)
            if let first = recentPresentations.first, time - first > Self.recentSpan {
                recentPresentations.removeAll { time - $0 > Self.recentSpan }
            }
        }
        shown[cycle] = cycleBins
    }

    /// How many frames reached the screen after `time`, on the clock of
    /// `CACurrentMediaTime`, looking back at most `recentSpan`.
    func presentations(after time: CFTimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recentPresentations.count { $0 > time }
    }

    func takeShown(cycle: Int) -> [Shown] {
        lock.lock()
        defer { lock.unlock() }
        let taken = shown[cycle] ?? [Shown](repeating: Shown(), count: CyclePacing.binCount)
        shown = shown.filter { $0.key > cycle }
        return taken
    }

    func record(cycle: Int, bin: Int, seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        var cycleBins = bins[cycle] ?? [Bin](repeating: Bin(), count: CyclePacing.binCount)
        cycleBins[bin].frames += 1
        cycleBins[bin].total += seconds
        cycleBins[bin].max = Swift.max(cycleBins[bin].max, seconds)
        if seconds > 1.0 / 60 { cycleBins[bin].overRefresh += 1 }
        bins[cycle] = cycleBins
    }

    /// The cycle's bins, forgetting them and any older cycle.
    func take(cycle: Int) -> [Bin] {
        lock.lock()
        defer { lock.unlock() }
        let taken = bins[cycle] ?? [Bin](repeating: Bin(), count: CyclePacing.binCount)
        bins = bins.filter { $0.key > cycle }
        return taken
    }
}

/// What the rest of the machine was doing: a freeze that coincides with the
/// process faulting pages in from disk, or with the system swapping, has a
/// different cause from one on an idle machine.
public struct SystemLoad: Sendable {
    public var cpuSeconds: Double
    public var majorFaults: Int
    public var involuntarySwitches: Int
    public var swapins: UInt64
    public var pageins: UInt64
    public var decompressions: UInt64

    public struct Change: Sendable, CustomStringConvertible {
        public var cores: Double
        public var majorFaults: Int
        public var involuntarySwitches: Int
        public var swapins: UInt64
        public var pageins: UInt64
        public var decompressions: UInt64
        public var thermal: String

        public var description: String {
            String(
                format: "process %.1f cores, %d major faults, %d preemptions · system %llu swap-ins, %llu page-ins, %llu decompressions · thermal %@",
                cores, majorFaults, involuntarySwitches, swapins, pageins, decompressions, thermal
            )
        }
    }

    public static func now() -> SystemLoad {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let ok = result == KERN_SUCCESS
        return SystemLoad(
            cpuSeconds: cpu,
            majorFaults: usage.ru_majflt,
            involuntarySwitches: usage.ru_nivcsw,
            swapins: ok ? vm.swapins : 0,
            pageins: ok ? vm.pageins : 0,
            decompressions: ok ? vm.decompressions : 0
        )
    }

    public func change(since earlier: SystemLoad, over seconds: TimeInterval) -> Change {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Change(
            cores: seconds > 0 ? (cpuSeconds - earlier.cpuSeconds) / seconds : 0,
            majorFaults: majorFaults - earlier.majorFaults,
            involuntarySwitches: involuntarySwitches - earlier.involuntarySwitches,
            swapins: swapins &- earlier.swapins,
            pageins: pageins &- earlier.pageins,
            decompressions: decompressions &- earlier.decompressions,
            thermal: thermal
        )
    }

    /// Asked for once: every call to `mach_host_self` takes a port reference.
    private static let host = mach_host_self()
}
