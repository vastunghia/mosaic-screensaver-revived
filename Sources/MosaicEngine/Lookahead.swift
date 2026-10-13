import Foundation
import MosaicCore

/// Builds the mosaics of the cycles to come, off the render thread.
///
/// SPEC § 2 wants the tiles to look as though they had always been there, so
/// nothing may be built while it is on screen. At k = 4 a solve costs about a
/// third of a second, which on the render thread is a visible hitch at every
/// join between cycles; here it is a background job started a whole cycle
/// before it is needed.
///
/// Solves are pure functions of (planner, rows, cycle, seed), so the thread a
/// mosaic was built on makes no difference to what it contains: a mosaic built
/// here is identical to one built synchronously. That is what keeps exports
/// reproducible, and a test holds it to that.
final class Lookahead: @unchecked Sendable {
    /// A mosaic, and why the planner could not make it if it could not.
    struct Built: Sendable {
        let planned: PlannedMosaic
        let error: String?
    }

    /// One mosaic built, and when, on the `systemUptime` clock: a freeze is
    /// read against what was running at the time.
    struct Job: Sendable {
        let cycle: Int
        let started: TimeInterval
        let finished: TimeInterval
        /// Built on the render thread because it was needed and not there.
        let onCaller: Bool
    }

    private let planner: any MosaicPlanner
    private let fallback: RandomMosaicPlanner
    private let seed: UInt64
    private let queue = DispatchQueue(label: "mosaic.lookahead", qos: .utility)

    private let lock = NSLock()
    private var rows: Int

    /// Bumped whenever the mosaics already built stop being valid — a change of
    /// R. A job carries the generation it was started under, and its result is
    /// dropped if that is no longer the current one.
    private var generation = 0
    private var ready: [Int: Built] = [:]
    private var pending: Set<Int> = []
    private var stallCount = 0
    private var jobs: [Job] = []

    init(planner: any MosaicPlanner, fallback: RandomMosaicPlanner, seed: UInt64, rows: Int) {
        self.planner = planner
        self.fallback = fallback
        self.seed = seed
        self.rows = rows
    }

    /// How many times a mosaic that should have been ready was not, and the
    /// caller had to build it itself. Some are unavoidable — the first cycle, a
    /// scrub, a change of R — but in steady state this has to stay put.
    var stalls: Int {
        lock.lock(); defer { lock.unlock() }
        return stallCount
    }

    /// Starts building `cycle` in the background, unless it is built or on its
    /// way already.
    func prefetch(_ cycle: Int) {
        guard cycle >= 0 else { return }
        lock.lock()
        guard ready[cycle] == nil, !pending.contains(cycle) else {
            lock.unlock()
            return
        }
        pending.insert(cycle)
        let job = (generation: generation, rows: rows)
        lock.unlock()

        queue.async { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            let built = build(cycle: cycle, rows: job.rows)
            record(Job(cycle: cycle, started: started, finished: ProcessInfo.processInfo.systemUptime, onCaller: false))
            lock.lock()
            if generation == job.generation {
                pending.remove(cycle)
                if ready[cycle] == nil { ready[cycle] = built }
            }
            lock.unlock()
        }
    }

    /// The mosaic of `cycle`, built here and now if it has to be.
    ///
    /// - Parameter counting: whether a synchronous build is a stall. It is on
    ///   the render path; offscreen rendering waits by design.
    func mosaic(forCycle cycle: Int, counting: Bool = true) -> Built {
        lock.lock()
        if let known = ready[cycle] {
            lock.unlock()
            return known
        }
        let rows = rows
        let current = generation
        if counting { stallCount += 1 }
        lock.unlock()

        // Built on the caller's thread rather than by waiting for the queue:
        // the queue may have other cycles ahead of this one. If a background
        // job for the same cycle is also running, it produces the identical
        // mosaic and whichever lands second is ignored.
        let started = ProcessInfo.processInfo.systemUptime
        let built = build(cycle: cycle, rows: rows)
        record(Job(cycle: cycle, started: started, finished: ProcessInfo.processInfo.systemUptime, onCaller: true))

        lock.lock()
        defer { lock.unlock() }
        if generation == current, ready[cycle] == nil { ready[cycle] = built }
        return ready[cycle] ?? built
    }

    /// The last few mosaics built, oldest first.
    var recentJobs: [Job] {
        lock.lock(); defer { lock.unlock() }
        return jobs
    }

    private func record(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        jobs.append(job)
        if jobs.count > 16 { jobs.removeFirst(jobs.count - 16) }
    }

    func isReady(_ cycle: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready[cycle] != nil
    }

    /// Forgets everything built, for a new R.
    func reset(rows: Int) {
        lock.lock(); defer { lock.unlock() }
        self.rows = rows
        generation += 1
        ready.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }

    /// Two live layers at a time (SPEC § 6), so nothing older than the previous
    /// cycle is worth keeping.
    func evict(before cycle: Int) {
        lock.lock(); defer { lock.unlock() }
        ready = ready.filter { $0.key >= cycle }
    }

    private func build(cycle: Int, rows: Int) -> Built {
        let subject = planner.subject(ofCycle: cycle)
        let previous = cycle > 0 ? planner.subject(ofCycle: cycle - 1) : planner.openingSubject
        let layoutSeed = seed &+ UInt64(bitPattern: Int64(cycle)) &* 0x2545_F491

        do {
            let planned = try planner.plan(
                rows: rows, subject: subject, previousSubject: previous, seed: layoutSeed
            )
            return Built(planned: planned, error: nil)
        } catch {
            // Degrading is a requirement, not a kindness: M10 has to survive an
            // index that is missing, empty or half-built, and showing something
            // beats showing nothing. The reason goes where it can be read.
            let planned = fallback.plan(
                rows: rows,
                subject: fallback.subject(ofCycle: cycle),
                previousSubject: cycle > 0 ? fallback.subject(ofCycle: cycle - 1) : nil,
                seed: layoutSeed
            )
            return Built(planned: planned, error: "\(error)")
        }
    }
}
