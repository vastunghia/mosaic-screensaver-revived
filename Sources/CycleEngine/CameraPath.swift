import Foundation
import MosaicCore

/// Where the camera is, in mosaic space.
public struct CameraState: Equatable, Sendable {
    public let center: NormalizedPoint

    /// How much of mosaic space is visible horizontally. Vertically it is the
    /// same number, because a mosaic is as wide-to-tall as the screen (SPEC § 4).
    public let visibleWidth: Double

    public init(center: NormalizedPoint, visibleWidth: Double) {
        self.center = center
        self.visibleWidth = visibleWidth
    }

    public var visibleRect: NormalizedRect {
        .centered(on: center, width: visibleWidth)
    }

    /// Where a point of mosaic space lands on screen, in screen widths from the
    /// centre: `(-0.5, -0.5)` is the top-left corner, `(0.5, 0.5)` the
    /// bottom-right one.
    public func project(_ point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: (point.x - center.x) / visibleWidth,
            y: (point.y - center.y) / visibleWidth
        )
    }
}

/// The path the camera follows over one cycle.
///
/// The naive implementation interpolates the centre from the anchor cell to the
/// middle of the mosaic, and it is wrong: it adds a pan that SPEC never asks
/// for, and the effect stops reading as a pure zoom. There is exactly one path
/// that hits both required endpoints *and* keeps the whole cycle a pure scaling
/// about a fixed point of the screen, and this is it:
///
///     k = R·(A − M) / (R − 1)      F = M + k      c(u) = F − k·w(u)
///
/// with `A` the centre of the anchor cell, `M` the centre of the mosaic and
/// `w(u)` the visible width. It gives `c(0) = A` and `c(1) = M`, and the screen
/// position of `F` works out to a constant `k`. Since `|A − M| ≤ ½ − ½/R`, that
/// constant satisfies `|k| ≤ ½`: the fixed point always falls inside the frame.
///
/// At a cycle boundary `k` changes, but `dw/du` is zero at both ends of the
/// curve and so `dc/du` vanishes with it — the join stays C¹-continuous.
public struct CameraPath: Equatable, Sendable {
    public let curve: ZoomCurve
    private let fixedPoint: NormalizedPoint
    private let k: NormalizedPoint

    public init(curve: ZoomCurve, anchorCenter: NormalizedPoint) {
        let r = curve.zoomFactor
        let m = NormalizedPoint.center
        let k = NormalizedPoint(
            x: r * (anchorCenter.x - m.x) / (r - 1),
            y: r * (anchorCenter.y - m.y) / (r - 1)
        )
        self.curve = curve
        self.k = k
        self.fixedPoint = NormalizedPoint(x: m.x + k.x, y: m.y + k.y)
    }

    public init(settings: MosaicSettings, anchor: GridCell) {
        self.init(
            curve: ZoomCurve(zoomFactor: settings.zoomFactor),
            anchorCenter: settings.geometry.center(of: anchor)
        )
    }

    public func camera(at u: Double) -> CameraState {
        let w = curve.visibleWidth(at: u)
        return CameraState(
            center: NormalizedPoint(x: fixedPoint.x - k.x * w, y: fixedPoint.y - k.y * w),
            visibleWidth: w
        )
    }

    /// The largest a rectangle of mosaic space ever appears on screen during the
    /// cycle, as a fraction of the screen width — 1 for the anchor cell, which
    /// fills the screen at `u = 0`.
    ///
    /// This is how many pixels a tile needs, and it is not "only the anchor":
    /// on a 4096-pixel screen at R = 60 the anchor's neighbours come on screen
    /// at once, some 4000 pixels wide, and are still wider than a 256-pixel
    /// atlas slice two thirds of the way through the cycle.
    ///
    /// Zooming out about a point of the screen only ever grows the part of
    /// mosaic space that is visible, so a rectangle on screen stays on screen,
    /// and it is largest at the first instant it appears. That instant is found
    /// by bisection. A rectangle never on screen before `u = 1` — impossible
    /// for one inside the mosaic — would give 0.
    public func largestOnScreenWidth(of rect: NormalizedRect) -> Double {
        func visible(_ u: Double) -> Bool {
            let seen = camera(at: u).visibleRect
            return rect.minX < seen.maxX && seen.minX < rect.maxX
                && rect.minY < seen.maxY && seen.minY < rect.maxY
        }
        guard visible(1) else { return 0 }

        var first = 0.0
        if !visible(0) {
            var hidden = 0.0, shown = 1.0
            for _ in 0..<60 {
                let middle = (hidden + shown) / 2
                if visible(middle) { shown = middle } else { hidden = middle }
            }
            first = shown
        }
        return min(1, rect.width / curve.visibleWidth(at: first))
    }

    /// The point of mosaic space that stays put on screen for the whole cycle.
    /// Exposed so a test can assert that it really does.
    public var invariantPoint: NormalizedPoint { fixedPoint }

    /// Where that point sits on screen: constant by construction, and inside the
    /// frame because `|k| ≤ ½`.
    public var invariantScreenPosition: NormalizedPoint { k }
}
