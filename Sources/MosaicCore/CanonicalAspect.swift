import Foundation

/// The one aspect ratio in the project.
///
/// SPEC § 4 makes tiles share the screen's aspect ratio, which is what makes a
/// cycle a pure scaling: going from "photograph filling the screen" to "one tile"
/// changes no crop. Every photograph therefore has a single canonical 16:9 crop
/// used at every scale, and tile and full-screen image are literally the same
/// texture at different mip levels.
///
/// It is a constant and not a setting on purpose: making the crop depend on the
/// display would make the *index* depend on the display, and the index is shared
/// between the app, the saver and every screen attached to the machine.
///
/// A screen of another shape is a rendering matter, not an indexing one: the
/// mosaic fills it and the excess is cropped, the same at every scale (`fill`).
public enum CanonicalAspect {
    public static let width = 16
    public static let height = 9

    public static let ratio = Double(width) / Double(height)

    /// The 16:9 height that goes with a width, rounded the one way everything in
    /// the project rounds it.
    public static func height(forWidth width: Int) -> Int {
        max(1, Int((Double(width) * Double(Self.height) / Double(Self.width)).rounded()))
    }

    /// How much of the camera's visible width a viewport of this shape shows,
    /// along each axis, when the 16:9 view fills it and the excess is cropped.
    /// One axis is always 1; the other is less on a screen of another shape:
    /// x on a narrower one (16:10, a laptop's 1.54), y on a wider one (21:9).
    /// Never more than 1, so the screen never shows past the edge of the mosaic,
    /// and never a stretch, so tiles keep their 16:9 on any screen.
    public static func fill(viewportWidth: Double, height: Double) -> (x: Double, y: Double) {
        guard viewportWidth > 0, height > 0 else { return (1, 1) }
        // Within a pixel of 16:9 is 16:9, as `height(forWidth:)` rounds it:
        // an 854×480 export stays exactly what it was.
        if abs(height - viewportWidth / ratio) < 1 { return (1, 1) }
        let viewport = viewportWidth / height
        return viewport < ratio ? (viewport / ratio, 1) : (1, ratio / viewport)
    }

    /// The width in pixels of the whole 16:9 view on a viewport of this size:
    /// the viewport's own width, or more when a narrower screen crops its sides.
    public static func filledWidth(viewportWidth: Double, height: Double) -> Double {
        max(viewportWidth, height * ratio)
    }
}
