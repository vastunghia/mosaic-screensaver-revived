import Foundation
import MosaicCore

/// The cycle state machine: given an absolute time, it says what the frame looks
/// like. Completely deterministic — hand it a time and assert on the result.
///
/// It does not build mosaics and does not know where photographs come from. It
/// only says *which* mosaics it will need and *when*, and someone else (M8) has
/// them ready in time.
public struct CycleEngine: Sendable {
    public var settings: MosaicSettings

    public init(settings: MosaicSettings) {
        self.settings = settings
    }

    public var curve: ZoomCurve { ZoomCurve(zoomFactor: settings.zoomFactor) }

    /// Splits an absolute time into a cycle index and a position within it.
    /// There are no pauses: cycle `n` ending and cycle `n + 1` starting are the
    /// same instant (SPEC § 2).
    public func position(at time: Double) -> CyclePosition {
        let cycles = time / settings.cycleDuration
        let index = Int(cycles.rounded(.down))
        return CyclePosition(index: index, u: cycles - Double(index))
    }

    /// The opacity of the previous mosaic *as a grid of tiles*, which fades to
    /// reveal the flat photograph underneath.
    ///
    /// Eased rather than linear: the crossfade is meant to pass unnoticed under
    /// the motion, and a linear ramp has visible corners at both ends. Its
    /// length and placement are still open (SPEC § 8, question 3), which is why
    /// they are settings and not constants.
    public func crossfade(at u: Double) -> Double {
        let span = (u - settings.crossfadeStart) / settings.crossfadeDuration
        return 1 - curve.ease(span)
    }

    public func camera(at u: Double, anchor: GridCell) -> CameraState {
        CameraPath(settings: settings, anchor: anchor).camera(at: u)
    }

    /// The mosaics that have to be ready at this instant: the one being revealed
    /// and the one after it. The lookahead is not optional — SPEC § 2 requires
    /// the tiles to look as though they had always been there, so nothing may be
    /// built while it is on screen.
    public func cyclesNeeded(at time: Double) -> ClosedRange<Int> {
        let index = position(at: time).index
        return index...(index + 1)
    }

    /// - Parameters:
    ///   - current: the mosaic being revealed this cycle.
    ///   - previous: the mosaic of the cycle before, which must be the
    ///     photograph sitting in `current`'s anchor cell.
    public func frame(
        at time: Double,
        current: MosaicLayout,
        previous: MosaicLayout?
    ) -> FrameState {
        let position = position(at: time)
        let camera = camera(at: position.u, anchor: current.anchor)

        var layer: PreviousLayer?
        if let previous {
            assert(
                current.anchoredPhoto == previous.subject,
                "the previous mosaic must be the photograph in the current anchor cell"
            )
            layer = PreviousLayer(
                layout: previous,
                cell: current.anchor,
                rect: current.geometry.rect(of: current.anchor),
                mosaicAlpha: crossfade(at: position.u)
            )
        }

        return FrameState(position: position, camera: camera, current: current, previous: layer)
    }
}
