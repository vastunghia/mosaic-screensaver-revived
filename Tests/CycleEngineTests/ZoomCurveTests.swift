import Foundation
import Testing
@testable import CycleEngine
import MosaicCore

@Suite("Zoom curve")
struct ZoomCurveTests {
    let curve = ZoomCurve(zoomFactor: 20)

    @Test("one cell fills the screen at the start, the whole mosaic at the end")
    func endpoints() {
        #expect(abs(curve.visibleWidth(at: 0) - 1.0 / 20) < 1e-15)
        #expect(abs(curve.visibleWidth(at: 1) - 1.0) < 1e-15)
        // Over a cycle the screen goes from showing 1/R of the mosaic to all of
        // it, which is the factor-of-R zoom of SPEC § 4.
        #expect(abs(curve.visibleWidth(at: 1) / curve.visibleWidth(at: 0) - 20) < 1e-12)
    }

    @Test("the zoom speed is zero at both ends, so cycles join without a seam")
    func zeroSpeedAtTheJoin() {
        #expect(curve.zoomRate(at: 0) == 0)
        #expect(curve.zoomRate(at: 1) == 0)

        // Also numerically, on the width itself rather than on the analytic
        // derivative: this is what the eye actually sees.
        let h = 1e-6
        let startSlope = (curve.visibleWidth(at: h) - curve.visibleWidth(at: 0)) / h
        let endSlope = (curve.visibleWidth(at: 1) - curve.visibleWidth(at: 1 - h)) / h
        #expect(abs(startSlope) < 1e-4)
        #expect(abs(endSlope) < 1e-4)
    }

    @Test("peak zoom speed is 1.5x the average, as SPEC § 3 says")
    func peakAgainstAverage() {
        let samples = stride(from: 0.0, through: 1.0, by: 1.0 / 10_000).map { curve.zoomRate(at: $0) }
        let peak = samples.max()!
        let mean = samples.reduce(0, +) / Double(samples.count)
        #expect(abs(peak - 1.5) < 1e-6)
        #expect(abs(peak / mean - 1.5) < 1e-3)
    }

    @Test("the easing is applied to the logarithm of the scale, not to the scale")
    func easingIsLogarithmic() {
        // Halfway through a cycle the scale is the geometric mean of its
        // endpoints, sqrt(R), not the arithmetic one. Getting this wrong is the
        // classic way to make a zoom feel like it lurches.
        let half = curve.visibleWidth(at: 0.5) / curve.visibleWidth(at: 0)
        #expect(abs(half - sqrt(20)) < 1e-12)
    }
}
