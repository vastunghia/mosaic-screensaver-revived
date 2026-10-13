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
    private var grids: [GridKey: TargetGrid] = [:]

    private struct GridKey: Hashable {
        let photo: String
        let rows: Int
        let detail: Int
    }

    /// - Parameter subjectCandidates: how many photographs of the shuffled deck
    ///   each cycle chooses its subject among, for the previous subject to fit
    ///   in. 1 is a plain deck.
    public init(
        catalog: any TileCatalog,
        options: SolverOptions = .standard,
        seed: UInt64 = 0x4D05_A1C0,
        subjectCandidates: Int = SolvedMosaicPlanner.defaultSubjectCandidates
    ) {
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
        // Every photograph is a tile; only those with the pixels to fill the
        // screen are subjects. All of them if none has, rather than none.
        let filling = entries.filter { catalog.canFillScreen($0.id) }
        let candidates = filling.isEmpty ? entries : filling
        subjects = candidates.map(\.id)
        sequence = SubjectSequence(
            count: max(1, candidates.count), seed: seed,
            signatures: candidates.map(\.signature), candidates: subjectCandidates
        )
    }

    public static let defaultSubjectCandidates = SubjectSequence.defaultCandidates

    public var isUsable: Bool { !pool.isEmpty }
    public var poolSize: Int { pool.count }

    public func subject(ofCycle index: Int) -> PhotoID {
        // An index with nothing usable in it is a state M10 has to survive, not
        // a programming error: the saver may be started before the app has ever
        // run. `layout` throws, the engine falls back, and the reason reaches
        // the readout.
        guard !subjects.isEmpty else { return PhotoID("") }
        return subjects[sequence.index(ofCycle: index + 1)]
    }

    /// The sequence's first photograph, so that cycle 0 opens on one that
    /// fills the screen, its close-up sharp, and its subject is chosen to
    /// fit it like any other. Left to the solver, the anchor was any tile:
    /// on an optimised library nine in ten have no more than 427 px
    /// (Sergio, 2026-10-13).
    public var openingSubject: PhotoID? {
        guard subjects.count > 1 else { return nil }
        return subjects[sequence.index(ofCycle: 0)]
    }

    public func plan(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed layoutSeed: UInt64
    ) throws -> PlannedMosaic {
        let key = GridKey(photo: subject.rawValue, rows: rows, detail: options.detail)

        lock.lock()
        var grid = grids[key]
        lock.unlock()

        if grid == nil {
            // Decoding, on the thread that asked — the engine's lookahead
            // thread, never the render thread.
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

        // Milestone 2's whole deliverable was a judgement, so the judgement is
        // instrumented, and the numbers go out with the mosaic they describe.
        return PlannedMosaic(layout: result.layout, statistics: result.statistics)
    }
}
