import Foundation
import MosaicCore
import MosaicEngine
import MosaicSolver

/// Which planner the engine gets, decided once so the window and the exporters
/// cannot disagree about it.
enum PlannerFactory {
    struct Resolved {
        let planner: (any MosaicPlanner)?
        let notes: [String]
    }

    static func make(options: Options, photos: PhotoSourceFactory.Resolved) -> Resolved {
        var notes: [String] = []

        guard !options.randomTiles else {
            return Resolved(planner: nil, notes: notes)
        }
        guard let indexed = photos.indexed else {
            // Synthetic photographs have no index and therefore no colours to
            // match on. Milestone 1's behaviour is the right fallback.
            return Resolved(planner: nil, notes: notes)
        }

        let solved = SolvedMosaicPlanner(
            catalog: IndexedTileCatalog(source: indexed),
            options: options.solverOptions,
            seed: options.seed,
            subjectCandidates: options.subjectCandidates
        )
        guard solved.isUsable else {
            notes.append("WARNING: the index has no usable signatures — falling back to random tiles")
            return Resolved(planner: nil, notes: notes)
        }
        if solved.poolSize < indexed.entries.count {
            notes.append("\(indexed.entries.count - solved.poolSize) photographs have no signature and were left out")
        }

        if !options.loop.isEmpty {
            let ring = options.loop.map(PhotoID.init)
            let missing = options.loop.filter { indexed.signature(for: PhotoID($0)) == nil }
            guard missing.isEmpty, ring.count >= 2, Set(ring).count == ring.count else {
                notes.append("WARNING: --loop needs two or more different photographs of the pool; not in it: \(missing.joined(separator: ", "))")
                return Resolved(planner: solved, notes: notes)
            }
            notes.append("loop: \(options.loop.joined(separator: " → ")) → \(options.loop[0]) …")
            return Resolved(planner: LoopingPlanner(inner: solved, ring: ring, seed: options.seed), notes: notes)
        }

        guard let wanted = options.subject else {
            return Resolved(planner: solved, notes: notes)
        }
        let id = PhotoID(wanted)
        guard indexed.signature(for: id) != nil else {
            notes.append("WARNING: no photograph called \(wanted) in the pool — leaving the subject to the seed")
            return Resolved(planner: solved, notes: notes)
        }
        notes.append("subject of cycle \(options.exportCycle) pinned to \(wanted)")
        return Resolved(
            planner: PinnedSubjectPlanner(inner: solved, cycle: options.exportCycle, subject: id),
            notes: notes
        )
    }
}

/// Forces one cycle to depict a chosen photograph.
///
/// Comparing two solver settings on two different target photographs compares
/// the photographs, so this exists purely to make an export reproducible enough
/// to argue about. It touches one cycle, leaving the one before it alone, so B
/// is still a photograph the mosaic has a reason to hold.
struct PinnedSubjectPlanner: MosaicPlanner {
    let inner: any MosaicPlanner
    let cycle: Int
    let subject: PhotoID

    func subject(ofCycle index: Int) -> PhotoID {
        index == cycle ? subject : inner.subject(ofCycle: index)
    }

    var openingSubject: PhotoID? {
        let opening = inner.openingSubject
        return cycle == 0 && opening == subject ? nil : opening
    }

    func plan(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed: UInt64
    ) throws -> PlannedMosaic {
        try inner.plan(rows: rows, subject: subject, previousSubject: previousSubject, seed: seed)
    }
}
