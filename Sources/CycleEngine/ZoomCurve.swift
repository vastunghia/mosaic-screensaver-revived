import Foundation

/// The zoom curve of SPEC § 3.
///
/// Acceleration and deceleration are *perceived*, so the easing is applied to
/// the logarithm of the scale, not to the scale: `scale(u) = R ^ smoothstep(u)`.
/// smoothstep has zero derivative at both ends, which is what makes the join
/// between one cycle and the next C¹-continuous without any special case.
public struct ZoomCurve: Equatable, Sendable {
    /// `R`: the magnification of one whole cycle.
    public let zoomFactor: Double

    public init(zoomFactor: Double) {
        precondition(zoomFactor > 1, "a cycle has to zoom out by more than 1x")
        self.zoomFactor = zoomFactor
    }

    /// `smoothstep(u) = u²(3 − 2u)`, clamped outside `[0, 1]`.
    public func ease(_ u: Double) -> Double {
        let t = min(max(u, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// `d(ease)/du = 6u(1 − u)`. Zero at both ends, peaking at 1.5 in the middle
    /// against a mean of 1 — the "peak speed is 1.5x the average" of SPEC § 3.
    public func easeRate(_ u: Double) -> Double {
        guard u > 0, u < 1 else { return 0 }
        return 6 * u * (1 - u)
    }

    /// How much of mosaic space the screen shows at `u`.
    ///
    /// At `u = 0` exactly one cell fills the screen, so the width is `1/R`; at
    /// `u = 1` the whole mosaic fills the screen, so it is `1`. Hence
    /// `w(u) = R^(ease(u) − 1)`.
    public func visibleWidth(at u: Double) -> Double {
        pow(zoomFactor, ease(u) - 1)
    }

    /// The perceived zoom speed: the derivative of the log of the scale, in
    /// e-folds of `R` per unit of `u`. This is the quantity the eye judges, and
    /// the one the curve is shaped to control.
    public func zoomRate(at u: Double) -> Double {
        easeRate(u)
    }
}
