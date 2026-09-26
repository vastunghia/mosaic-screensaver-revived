import Foundation
import MosaicCore
import MosaicSolver

/// The planner that makes a real photomosaic: a thin bridge between a catalogue
/// of colours and M3.
public final class SolvedMosaicPlanner: MosaicPlanner, @unchecked Sendable {
    public let catalog: any TileCatalog
    public let options: SolverOptions
    public let seed: UInt64

    private let pool: [PoolEntry]
    private let subjects: [PhotoID]
    private let sequence: SubjectSequence
    private let lock = NSLock()
    private var statistics: SolveStatistics?
    private var grids: [GridKey: TargetGrid] = [:]

    private struct GridKey: Hashable {
        let photo: String
        let rows: Int
        let detail: Int
    }

    public init(catalog: any TileCatalog, options: SolverOptions = .standard, seed: UInt64 = 0x4D05_A1C0) {
        self.catalog = catalog
        self.options = options
        self.seed = seed

        // A photograph with no signature cannot be matched, so it is not in the
        // pool. It is dropped here, once, rather than checked for per cell.
        var entries: [PoolEntry] = []
        for photo in catalog.photos {
            guard let signature = catalog.signature(for: photo) else { continue }
            entries.append(PoolEntry(id: photo, signature: signature))
        }
        pool = entries
        subjects = entries.map(\.id)
        sequence = SubjectSequence(count: max(1, entries.count), seed: seed)
    }

    public var isUsable: Bool { !pool.isEmpty }
    public var poolSize: Int { pool.count }

    /// The numbers from the last mosaic built. Milestone 2's whole deliverable is
    /// a judgement, so the judgement is instrumented.
    public var lastStatistics: SolveStatistics? {
        lock.lock(); defer { lock.unlock() }
        return statistics
    }

    public func subject(ofCycle index: Int) -> PhotoID {
        // An index with nothing usable in it is a state M10 has to survive, not
        // a programming error: the saver may be started before the app has ever
        // run. `layout` throws, the engine falls back, and the reason reaches
        // the readout.
        guard !subjects.isEmpty else { return PhotoID("") }
        return subjects[sequence.index(ofCycle: index)]
    }

    public func layout(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed layoutSeed: UInt64
    ) throws -> MosaicLayout {
        let key = GridKey(photo: subject.rawValue, rows: rows, detail: options.detail)

        lock.lock()
        var grid = grids[key]
        lock.unlock()

        if grid == nil {
            // Decoding, on the thread that asked. Milestone 1 built layouts
            // synchronously one cycle ahead and this keeps doing that; moving the
            // work to the background is M8's job proper, in milestone 3.
            let decoded = try catalog.targetGrid(for: subject, rows: rows, detail: options.detail)
            lock.lock()
            // Two live layers at a time (SPEC § 6), so a handful of grids is
            // every grid that can still be wanted.
            if grids.count > 4 { grids.removeAll(keepingCapacity: true) }
            grids[key] = decoded
            lock.unlock()
            grid = decoded
        }

        let result = try MosaicSolver.solve(
            target: grid!,
            subject: subject,
            previousSubject: previousSubject,
            pool: pool,
            options: options,
            seed: layoutSeed
        )

        lock.lock()
        statistics = result.statistics
        lock.unlock()

        return result.layout
    }
}
