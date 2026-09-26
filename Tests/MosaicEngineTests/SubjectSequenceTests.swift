import Foundation
import MosaicCore
import Testing
@testable import MosaicEngine

@Suite("Subject sequence")
struct SubjectSequenceTests {
    /// Region colours that differ from photograph to photograph, so some fit a
    /// given colour and most do not.
    private func signatures(_ count: Int, seed: UInt64 = 3) -> [TileSignature] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            TileSignature(side: 4, cells: (0..<16).map { _ in
                LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit())
            })
        }
    }

    @Test("every photograph is shown once before any is shown twice")
    func aDeckNotADie() {
        let count = 50
        let sequence = SubjectSequence(count: count, seed: 7, signatures: signatures(count))
        for epoch in 0..<3 {
            let shown = (epoch * count..<(epoch + 1) * count).map(sequence.index(ofCycle:))
            #expect(Set(shown).count == count, "epoch \(epoch)")
        }
    }

    @Test("no cycle repeats the one before, across reshuffles too")
    func neverTwiceInARow() {
        for seed in UInt64(0)..<20 {
            let sequence = SubjectSequence(count: 5, seed: seed, signatures: signatures(5))
            for cycle in 1..<60 {
                #expect(sequence.index(ofCycle: cycle) != sequence.index(ofCycle: cycle - 1))
            }
        }
    }

    @Test("choosing among candidates makes the last subject fit the next one better")
    func candidatesImproveTheFit() {
        let count = 400
        let pool = signatures(count)
        func meanFit(candidates: Int) -> Double {
            let sequence = SubjectSequence(count: count, seed: 11, signatures: pool, candidates: candidates)
            let fits = (1..<count).map { cycle in
                sequence.fit(of: sequence.index(ofCycle: cycle - 1), in: sequence.index(ofCycle: cycle))
            }
            return fits.reduce(0, +) / Double(fits.count)
        }
        let plain = meanFit(candidates: 1)
        let chosen = meanFit(candidates: 8)
        #expect(chosen < plain * 0.8, "\(plain) -> \(chosen)")
    }

    @Test("a cycle's subject does not depend on which cycles were asked for first")
    func orderOfQuestionsDoesNotMatter() {
        let pool = signatures(30)
        let walked = SubjectSequence(count: 30, seed: 5, signatures: pool)
        let expected = (0..<100).map(walked.index(ofCycle:))
        let jumped = SubjectSequence(count: 30, seed: 5, signatures: pool)
        #expect(jumped.index(ofCycle: 99) == expected[99])
        #expect((0..<100).map(jumped.index(ofCycle:)) == expected)
    }

    @Test("one photograph is shown every cycle, rather than nothing")
    func aPoolOfOne() {
        let sequence = SubjectSequence(count: 1, seed: 1, signatures: signatures(1))
        #expect((0..<5).map(sequence.index(ofCycle:)) == [0, 0, 0, 0, 0])
    }
}
