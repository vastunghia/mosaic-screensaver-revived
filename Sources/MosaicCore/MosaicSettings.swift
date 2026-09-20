import Foundation

/// The two knobs the original exposed (SPEC § 7), plus the crossfade, which is
/// still an open question and therefore has to be adjustable while we look at it.
public struct MosaicSettings: Equatable, Sendable {
    /// `R`: rows, columns, and the zoom factor of one cycle. The usable range is
    /// 30 to 90 (SPEC § 4), decided by watching the effect rather than by
    /// reasoning about it. Smaller values stay legal because the tests use them.
    public var rows: Int

    /// `T`: the seconds one cycle takes, from photograph B filling the screen to
    /// photograph C filling the screen.
    public var cycleDuration: Double

    /// When the mosaic-to-photograph crossfade begins, in cycle-relative time
    /// `u = t / T`.
    public var crossfadeStart: Double

    /// How long that crossfade lasts, in units of `u`. It is far longer than the
    /// two seconds first supposed: 0.30 of a cycle, about 7.5 s at the default
    /// `T` (SPEC § 2).
    public var crossfadeDuration: Double

    public init(
        rows: Int = 60,
        cycleDuration: Double = 25,
        crossfadeStart: Double = 0,
        crossfadeDuration: Double = 0.30
    ) {
        precondition(rows >= 2, "a mosaic needs at least 2 rows")
        precondition(cycleDuration > 0, "a cycle needs a positive duration")
        precondition(crossfadeDuration > 0, "a crossfade needs a positive duration")
        precondition(
            crossfadeStart >= 0 && crossfadeStart + crossfadeDuration <= 1,
            "the crossfade has to fit inside one cycle"
        )
        self.rows = rows
        self.cycleDuration = cycleDuration
        self.crossfadeStart = crossfadeStart
        self.crossfadeDuration = crossfadeDuration
    }

    /// `R` as the zoom factor it also is.
    public var zoomFactor: Double { Double(rows) }

    public var geometry: GridGeometry { GridGeometry(rows: rows) }
}
