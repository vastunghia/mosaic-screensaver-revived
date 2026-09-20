import Foundation

/// A point in *mosaic space*: the unit square that covers one whole `R × R`
/// mosaic, with the origin at the top-left corner, `x` growing right and `y`
/// growing down.
///
/// Mosaic space is normalised, so it carries no aspect ratio of its own. It can
/// afford not to because SPEC § 4 fixes the tile aspect to the screen aspect,
/// which makes a mosaic exactly as wide-to-tall as the screen it fills. The
/// aspect ratio therefore only enters at projection time, in the renderer.
public struct NormalizedPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

/// An axis-aligned rectangle in mosaic space.
public struct NormalizedRect: Equatable, Sendable {
    public var origin: NormalizedPoint
    public var width: Double
    public var height: Double

    public init(origin: NormalizedPoint, width: Double, height: Double) {
        self.origin = origin
        self.width = width
        self.height = height
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: NormalizedPoint(x: x, y: y), width: width, height: height)
    }

    /// The rectangle covering a whole mosaic.
    public static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + width }
    public var maxY: Double { origin.y + height }

    public var center: NormalizedPoint {
        NormalizedPoint(x: origin.x + width / 2, y: origin.y + height / 2)
    }

    /// The rectangle seen by a camera centred on `center` showing `width` of
    /// mosaic space horizontally. The height follows from the mosaic being as
    /// wide-to-tall as the screen (SPEC § 4), so a square in mosaic space is a
    /// screenful.
    public static func centered(on center: NormalizedPoint, width: Double) -> NormalizedRect {
        NormalizedRect(
            x: center.x - width / 2,
            y: center.y - width / 2,
            width: width,
            height: width
        )
    }
}
