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
/// Known limitation, deferred to M7/M10: mosaic space assumes screen aspect
/// equals tile aspect. On a 16:10 display the mosaic has to be cropped or
/// letterboxed as a whole — which is a rendering decision, not an indexing one.
public enum CanonicalAspect {
    public static let width = 16
    public static let height = 9

    public static let ratio = Double(width) / Double(height)

    /// The 16:9 height that goes with a width, rounded the one way everything in
    /// the project rounds it.
    public static func height(forWidth width: Int) -> Int {
        max(1, Int((Double(width) * Double(Self.height) / Double(Self.width)).rounded()))
    }
}
