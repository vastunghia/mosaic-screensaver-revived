import Foundation
import MosaicCore

/// Where we are in the endless zoom: which cycle, and how far through it.
public struct CyclePosition: Equatable, Sendable {
    /// Counts up forever. Cycle `n` ends exactly where cycle `n + 1` begins.
    public let index: Int

    /// `u = t/T`, in `[0, 1)`.
    public let u: Double

    public init(index: Int, u: Double) {
        self.index = index
        self.u = u
    }
}

/// The previous cycle's mosaic, seen from the current one.
///
/// It occupies a single cell of the current mosaic, and over the crossfade of
/// SPEC § 2 it stops being a grid of tiles and becomes one flat photograph.
/// That swap is the reset that stops the recursion going on for ever, and the
/// motion is what hides it.
public struct PreviousLayer: Equatable, Sendable {
    /// The previous cycle's own mosaic, drawn as a grid while it still is one.
    public let layout: MosaicLayout

    /// Which cell of the current mosaic it sits in.
    public let cell: GridCell

    /// That cell's rectangle, in the current mosaic's space.
    public let rect: NormalizedRect

    /// 1 while it is still a grid of tiles, 0 once it is a flat photograph.
    public let mosaicAlpha: Double

    /// The photograph the flat version shows.
    public var photo: PhotoID { layout.subject }

    public init(layout: MosaicLayout, cell: GridCell, rect: NormalizedRect, mosaicAlpha: Double) {
        self.layout = layout
        self.cell = cell
        self.rect = rect
        self.mosaicAlpha = mosaicAlpha
    }
}

/// Everything the renderer needs for one frame, and nothing else. It knows
/// nothing about photographs, files or time — which is exactly what makes the
/// renderer testable on its own.
public struct FrameState: Equatable, Sendable {
    public let position: CyclePosition
    public let camera: CameraState

    /// The mosaic being revealed.
    public let current: MosaicLayout

    /// The one before it. Absent only on the very first cycle, before there is
    /// a previous photograph to have come from.
    public let previous: PreviousLayer?

    public init(
        position: CyclePosition,
        camera: CameraState,
        current: MosaicLayout,
        previous: PreviousLayer?
    ) {
        self.position = position
        self.camera = camera
        self.current = current
        self.previous = previous
    }

    /// The cells of the current mosaic the screen actually touches. At the start
    /// of a cycle this is one cell out of `R²`; at the end it is all of them
    /// (SPEC § 6).
    public var visibleCells: GridCellRange {
        current.geometry.cells(intersecting: camera.visibleRect)
    }
}
