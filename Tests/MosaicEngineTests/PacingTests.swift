import Foundation
import Testing
@testable import MosaicEngine

@Suite("Pacing")
struct PacingTests {
    private let frame = 1.0 / 60
    private let threshold = MosaicEngine.freezeThreshold

    /// A host running normally: isReady, then advance, every sixtieth.
    private func run(
        _ tracker: inout PacingTracker, frames: Int, from wall: inout Double, time: inout Double
    ) -> [PacingTracker.Gap] {
        var gaps: [PacingTracker.Gap] = []
        for _ in 0..<frames {
            wall += frame
            time += frame
            tracker.call(at: wall)
            if let gap = tracker.frame(.init(wall: wall, time: time, presented: true)) { gaps.append(gap) }
        }
        return gaps
    }

    @Test("A steady run has no freezes, only frame-long gaps")
    func steady() {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        let gaps = run(&tracker, frames: 120, from: &wall, time: &time)
        #expect(gaps.count == 119)
        #expect(gaps.allSatisfy { abs($0.duration - frame) < 1e-9 })
        #expect(gaps.allSatisfy { $0.duration < threshold })
    }

    @Test("Nobody calling for two seconds is a stopped freeze")
    func stopped() throws {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        _ = run(&tracker, frames: 10, from: &wall, time: &time)
        wall += 2
        time += 0.25
        tracker.call(at: wall)
        let result = tracker.frame(.init(wall: wall, time: time, presented: true))
        let gap = try #require(result)
        #expect(abs(gap.duration - (2 + frame * 0)) < 0.02)
        #expect(gap.kind(threshold: threshold) == .stopped)
        #expect(abs(gap.animationStep - 0.25) < 1e-9)
    }

    @Test("An engine that says not ready holds the clock, and says why")
    func held() throws {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        _ = run(&tracker, frames: 10, from: &wall, time: &time)
        for _ in 0..<60 {
            wall += frame
            tracker.notReady("close-ups of cycle 3 loading", at: wall)
            let none = tracker.frame(.init(wall: wall, time: time, presented: true))
            #expect(none == nil)
        }
        wall += frame
        time += frame
        let result = tracker.frame(.init(wall: wall, time: time, presented: true))
        let gap = try #require(result)
        #expect(gap.kind(threshold: threshold) == .held)
        #expect(gap.tally.notReady["close-ups of cycle 3 loading"] == 60)
        #expect(gap.tally.staticFrames == 60)
        #expect(gap.tally.longestSilence < threshold)
    }

    @Test("A paused clock with frames still drawn is not a freeze")
    func paused() throws {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        _ = run(&tracker, frames: 10, from: &wall, time: &time)
        for _ in 0..<120 {
            wall += frame
            tracker.call(at: wall)
            _ = tracker.frame(.init(wall: wall, time: time, presented: true))
        }
        wall += frame
        time += frame
        let result = tracker.frame(.init(wall: wall, time: time, presented: true))
        let gap = try #require(result)
        #expect(gap.duration > 1)
        #expect(gap.kind(threshold: threshold) == nil)
    }

    @Test("Frames that wait long for a drawable point at the GPU")
    func gpu() throws {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        _ = run(&tracker, frames: 10, from: &wall, time: &time)
        wall += 0.4
        time += 0.25
        let result = tracker.frame(.init(
            wall: wall, time: time, presented: true, drawableWait: 0.38, duration: 0.39
        ))
        let gap = try #require(result)
        #expect(gap.kind(threshold: threshold) == .gpu)
    }

    @Test("Frames not presented are counted, and the gap spans them")
    func unpresented() throws {
        var tracker = PacingTracker()
        var wall = 100.0, time = 0.0
        _ = run(&tracker, frames: 10, from: &wall, time: &time)
        for _ in 0..<10 {
            wall += frame
            time += frame
            let none = tracker.frame(.init(wall: wall, time: time, presented: false))
            #expect(none == nil)
        }
        wall += frame
        time += frame
        let result = tracker.frame(.init(wall: wall, time: time, presented: true))
        let gap = try #require(result)
        #expect(gap.kind(threshold: threshold) == .unpresented)
        #expect(gap.tally.unpresented == 10)
        #expect(abs(gap.duration - 11 * frame) < 1e-9)
    }
}
