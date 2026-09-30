import AppKit
import Foundation
import IOKit
import MosaicEngine
import os

/// What only the host can see about a freeze: whether its main thread was
/// blocked, and what the GPUs and the rest of the machine were doing.
///
/// The engine finds freezes by itself (`Freeze`), but it cannot tell a main
/// thread stuck in a call from a display link that stopped firing, and it has
/// no business reading IOKit. So the host keeps three things running beside
/// it:
///
/// - a watchdog that pings the main thread ten times a second and, while a
///   ping goes unanswered past `blockedThreshold`, reads the main thread's
///   stack every tick (`MainThreadBacktrace`); the stacks go to the log and to
///   a file in `~/Library/Logs/Mosaic`;
/// - each GPU's utilisation, read from IOKit twice a second and kept for half
///   a minute, so a freeze can be read against it;
/// - after a long freeze, the processes busiest on the CPU;
/// - whether the window was visible and the displays awake: macOS stops the
///   display link of a window that is covered, and that looks exactly like a
///   freeze from inside.
///
/// Everything goes to the unified log, subsystem `com.vastunghia.Mosaic`, next
/// to the engine's own lines, so a run can be read back with
/// `/usr/bin/log show --predicate 'subsystem == "com.vastunghia.Mosaic"'`.
final class PacingProbe: @unchecked Sendable {
    static let shared = PacingProbe()

    /// A main thread that does not answer within this long is logged, and
    /// its stack read until it does.
    let blockedThreshold: TimeInterval = 0.25

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Mosaic", isDirectory: true)

    private let queue = DispatchQueue(label: "mosaic.probe", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pingSent: TimeInterval?
    private var backtrace: MainThreadBacktrace?
    private var stacks: [[UInt]] = []
    /// Symbolicating calls `atos`, which takes a while: not on the queue the
    /// watchdog ticks on.
    private let reporting = DispatchQueue(label: "mosaic.probe.report", qos: .utility)
    private var ticks = 0
    private var gpuLoads: [(time: TimeInterval, percent: [String: Int])] = []
    /// When the window stopped being visible, or the displays slept, and when
    /// that ended; nil while it lasts.
    private var hidden: [(from: TimeInterval, to: TimeInterval?, why: String)] = []
    private var observers: [NSObjectProtocol] = []

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "probe")

    /// Idempotent: the player and the harness both call it when their view
    /// reaches a window. Called on the main thread, which is the one it
    /// watches.
    func start() {
        let backtrace = Thread.isMainThread ? MainThreadBacktrace() : nil
        queue.async { [self] in
            guard timer == nil else { return }
            self.backtrace = backtrace
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            Self.log.notice("probe started, pid \(getpid(), privacy: .public)")
        }
    }

    /// Adds the host's view of a freeze to the log, off the main thread: `ps`
    /// takes tens of milliseconds, which on the main thread would be a hitch of
    /// its own.
    func describe(_ freeze: Freeze) {
        queue.async { [self] in
            let window = (freeze.start - 0.5)...(freeze.start + freeze.duration + 0.5)
            var peaks: [String: Int] = [:]
            for load in gpuLoads where window.contains(load.time) {
                for (gpu, percent) in load.percent { peaks[gpu] = max(peaks[gpu] ?? 0, percent) }
            }
            var parts = [String(format: "freeze at %.2f s", freeze.start)]
            let end = freeze.start + freeze.duration
            for span in hidden where span.from <= end && (span.to ?? .infinity) >= freeze.start {
                parts.append(String(format: "%@ from %+.2f s", span.why, span.from - freeze.start)
                    + (span.to.map { String(format: " to %+.2f s", $0 - freeze.start) } ?? ", still"))
            }
            parts.append(peaks.isEmpty
                ? "GPU utilisation not known"
                : "GPU utilisation peak " + peaks.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)%" }.joined(separator: ", "))
            if freeze.duration >= 0.5 {
                parts.append("busiest processes now: " + Self.busiestProcesses().joined(separator: ", "))
            }
            let line = parts.joined(separator: " · ")
            Self.log.notice("\(line, privacy: .public)")
            print(line)
            fflush(stdout)
        }
    }

    // MARK: - Visibility

    /// Follows `window`'s occlusion and the displays' sleep, on the main thread.
    @MainActor
    func watch(_ window: NSWindow) {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0); workspace.removeObserver($0) }
        observers = [
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                let visible = MainActor.assumeIsolated { window.occlusionState.contains(.visible) }
                self?.mark(visible ? nil : "window not visible")
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
                [weak self] _ in self?.mark("displays asleep")
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
                [weak self] _ in self?.mark(nil)
            },
        ]
    }

    /// Starts a hidden stretch, or ends the current one when `why` is nil.
    private func mark(_ why: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            if let last = hidden.indices.last, hidden[last].to == nil {
                guard why == nil else { return }
                hidden[last].to = now
                let ended = hidden[last].why
                Self.log.notice("\(ended, privacy: .public) until now")
            } else if let why {
                hidden.append((now, nil, why))
                if hidden.count > 16 { hidden.removeFirst(hidden.count - 16) }
                Self.log.notice("\(why, privacy: .public)")
            }
        }
    }

    // MARK: - Watchdog

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let sent = pingSent {
            if now - sent >= blockedThreshold, let backtrace { stacks.append(backtrace.capture()) }
        } else {
            pingSent = now
            DispatchQueue.main.async { [self] in
                let answered = ProcessInfo.processInfo.systemUptime
                queue.async { self.answered(sent: now, at: answered) }
            }
        }

        ticks += 1
        if ticks % 5 == 0 { recordGPULoad(at: now) }
    }

    private func answered(sent: TimeInterval, at answered: TimeInterval) {
        let waited = answered - sent
        let captured = stacks
        pingSent = nil
        stacks = []
        guard waited >= blockedThreshold else { return }
        reporting.async { [self] in report(blockedFor: waited, from: sent, stacks: captured) }
    }

    /// One line in the log with the stack seen most often, and every distinct
    /// stack, with how often it was seen, in a file.
    private func report(blockedFor waited: TimeInterval, from sent: TimeInterval, stacks: [[UInt]]) {
        var line = String(format: "main thread blocked for at least %.2f s, from %.2f s", waited, sent)
        let seen = stacks.filter { !$0.isEmpty }
        if !seen.isEmpty {
            let names = MainThreadBacktrace.symbolicate(seen.flatMap { $0 })
            var counts: [[UInt]: Int] = [:]
            for stack in seen { counts[stack, default: 0] += 1 }
            let ranked = counts.sorted { $0.value > $1.value }
            let top = ranked[0]
            line += " · \(top.value) of \(seen.count) stacks: "
                + top.key.prefix(14).map { names[$0] ?? "?" }.joined(separator: " ← ")

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let file = directory.appendingPathComponent("hang-\(formatter.string(from: Date())).txt")
            var text = String(format: "Main thread blocked for at least %.2f s, from %.2f s (systemUptime).\n", waited, sent)
            text += "\(seen.count) stacks, one every 0.1 s while it did not answer.\n"
            for (stack, count) in ranked {
                text += "\n\(count) × \n" + stack.map { "    " + (names[$0] ?? "?") }.joined(separator: "\n") + "\n"
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
                line += " · all in \(file.path)"
            } catch {
                line += " · could not write the stacks: \(error)"
            }
        }
        Self.log.notice("\(line, privacy: .public)")
        print(line)
        fflush(stdout)
    }

    // MARK: - GPU utilisation

    private func recordGPULoad(at time: TimeInterval) {
        gpuLoads.append((time, Self.gpuUtilisation()))
        if gpuLoads.count > 60 { gpuLoads.removeFirst(gpuLoads.count - 60) }
    }

    /// "Device Utilization %" of every GPU, by the family name in its
    /// accelerator class: `AMDRadeonX4000_AMDBaffinGraphicsAccelerator` is
    /// the Radeon Pro 560X, `…Navi21…` the RX 6800.
    private static func gpuUtilisation() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let percent = statistics["Device Utilization %"] as? Int
            else { continue }
            var name = (IOObjectCopyClass(service)?.takeRetainedValue() as String?) ?? "GPU"
            if let range = name.range(of: "_AMD") { name = String(name[range.upperBound...]) }
            name = name.replacingOccurrences(of: "GraphicsAccelerator", with: "")
            while result[name] != nil { name += "'" }
            result[name] = percent
        }
        return result
    }

    // MARK: - Processes

    private static func busiestProcesses() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pcpu=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ["ps failed"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(6)
            .map { line in
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { return String(line) }
                return "\((fields[1] as Substring).split(separator: "/").last ?? "") \(fields[0])%"
            }
    }
}
