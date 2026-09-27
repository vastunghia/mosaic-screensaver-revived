import Foundation
import MosaicCore
import Testing
@testable import MosaicEngine

@Suite("Lookahead")
struct LookaheadTests {
    private let pool = (0..<50).map { PhotoID("photo-\($0)") }

    private func lookahead(rows: Int = 8, planner: (any MosaicPlanner)? = nil) -> Lookahead {
        let fallback = RandomMosaicPlanner(pool: pool, seed: 5)
        return Lookahead(planner: planner ?? fallback, fallback: fallback, seed: 11, rows: rows)
    }

    private func waitUntilReady(_ lookahead: Lookahead, _ cycles: some Sequence<Int>) throws {
        let deadline = Date().addingTimeInterval(10)
        for cycle in cycles {
            while !lookahead.isReady(cycle) {
                try #require(Date() < deadline, "cycle \(cycle) never arrived")
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    @Test("a mosaic built in the background is the one built synchronously")
    func backgroundMatchesSynchronous() throws {
        // What keeps exports reproducible: the thread a mosaic was built on
        // must make no difference to what it contains.
        let background = lookahead()
        for cycle in 0..<6 { background.prefetch(cycle) }
        try waitUntilReady(background, 0..<6)

        let synchronous = lookahead()
        for cycle in 0..<6 {
            #expect(
                background.mosaic(forCycle: cycle).planned.layout
                    == synchronous.mosaic(forCycle: cycle, counting: false).planned.layout,
                "cycle \(cycle)"
            )
        }
    }

    @Test("a mosaic prefetched in time is not a stall; one asked for cold is")
    func stallsCountOnlyTheLate() throws {
        let subject = lookahead()
        subject.prefetch(3)
        try waitUntilReady(subject, [3])

        _ = subject.mosaic(forCycle: 3)
        #expect(subject.stalls == 0)

        _ = subject.mosaic(forCycle: 4)
        #expect(subject.stalls == 1)

        // Offscreen rendering waits by design, and is not counted.
        _ = subject.mosaic(forCycle: 5, counting: false)
        #expect(subject.stalls == 1)
    }

    @Test("a mosaic started for an old R never arrives under the new one")
    func resetDropsTheOldGeneration() throws {
        let slow = SlowPlanner(inner: RandomMosaicPlanner(pool: pool, seed: 5))
        let subject = lookahead(rows: 8, planner: slow)

        // Started at R = 8 and still running when R changes: whichever way the
        // race goes, what comes back has the new R.
        subject.prefetch(2)
        subject.reset(rows: 4)
        Thread.sleep(forTimeInterval: 0.1)

        #expect(subject.mosaic(forCycle: 2).planned.layout.rows == 4)
    }

    @Test("a failing planner degrades to random tiles and says why")
    func failureFallsBack() {
        let subject = lookahead(planner: FailingPlanner())
        let built = subject.mosaic(forCycle: 1)
        #expect(built.error != nil)
        #expect(built.planned.layout.tiles.count == 64)
    }
}

private struct SlowPlanner: MosaicPlanner {
    let inner: RandomMosaicPlanner

    func subject(ofCycle index: Int) -> PhotoID { inner.subject(ofCycle: index) }

    func plan(rows: Int, subject: PhotoID, previousSubject: PhotoID?, seed: UInt64) -> PlannedMosaic {
        Thread.sleep(forTimeInterval: 0.05)
        return inner.plan(rows: rows, subject: subject, previousSubject: previousSubject, seed: seed)
    }
}

private struct FailingPlanner: MosaicPlanner {
    struct Failure: Error {}

    func subject(ofCycle index: Int) -> PhotoID { PhotoID("x") }

    func plan(rows: Int, subject: PhotoID, previousSubject: PhotoID?, seed: UInt64) throws -> PlannedMosaic {
        throw Failure()
    }
}
