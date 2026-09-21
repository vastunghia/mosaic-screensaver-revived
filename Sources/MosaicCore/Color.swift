import Foundation

/// A colour in linear-light sRGB primaries.
///
/// **The module invariant lives here.** Every reduction in this project — a
/// signature, a mosaic cell's mean, a mip level — is an average of `LinearRGB`
/// values. `LabColor` appears only at the leaves, where two colours are
/// compared, and Lab values are never averaged.
///
/// The reason is not pedantry. sRGB is gamma-encoded, so averaging encoded
/// values is averaging the wrong numbers: half black and half white has an
/// encoded mean of 127.5, which is 21.6% of the light, where the true mean is
/// 50%, encoded as 188. Sixty codes of error out of 255, and worst on the
/// high-contrast photographs a mosaic is mostly made of.
public struct LinearRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = LinearRGB(r: 0, g: 0, b: 0)
    public static let white = LinearRGB(r: 1, g: 1, b: 1)

    /// From 8-bit sRGB, through the decoding lookup table.
    public init(srgb8 red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.init(
            r: SRGBTransfer.decoded8[Int(red)],
            g: SRGBTransfer.decoded8[Int(green)],
            b: SRGBTransfer.decoded8[Int(blue)]
        )
    }

    /// From sRGB components already in 0...1.
    public init(srgb red: Double, _ green: Double, _ blue: Double) {
        self.init(
            r: SRGBTransfer.decode(red),
            g: SRGBTransfer.decode(green),
            b: SRGBTransfer.decode(blue)
        )
    }

    /// Back to sRGB in 0...1. Only for writing pixels out and for tests; nothing
    /// in the matching path needs it.
    public var srgb: (r: Double, g: Double, b: Double) {
        (SRGBTransfer.encode(r), SRGBTransfer.encode(g), SRGBTransfer.encode(b))
    }

    public static func + (lhs: LinearRGB, rhs: LinearRGB) -> LinearRGB {
        LinearRGB(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b)
    }

    public static func * (lhs: LinearRGB, rhs: Double) -> LinearRGB {
        LinearRGB(r: lhs.r * rhs, g: lhs.g * rhs, b: lhs.b * rhs)
    }

    /// The mean of a sequence, which is the only way this project ever combines
    /// colours.
    public static func mean(of colours: some Collection<LinearRGB>) -> LinearRGB {
        guard !colours.isEmpty else { return .black }
        var total = LinearRGB.black
        for colour in colours { total = total + colour }
        return total * (1 / Double(colours.count))
    }
}

/// The sRGB electro-optical transfer function and its inverse.
public enum SRGBTransfer {
    /// sRGB code to light.
    public static func decode(_ value: Double) -> Double {
        value <= 0.040_450 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Light to sRGB code.
    public static func encode(_ value: Double) -> Double {
        value <= 0.003_130_8 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Decoding an 8-bit channel is done a few hundred million times while an
    /// index is built, and there are only 256 answers.
    public static let decoded8: [Double] = (0...255).map { decode(Double($0) / 255) }
}

/// How much two colours differ, per axis. Scaling the axes keeps the distance
/// Euclidean, which is what lets `deltaE` stay a metric.
///
/// Both default to 1, which makes `deltaE` plain CIE76. They exist because
/// luminance structure is what carries recognisability at tile size, while
/// chroma error is largely forgiven — but that is a claim to be settled by
/// looking at exports, not by argument.
public struct LabWeights: Equatable, Sendable {
    public var lightness: Double
    public var chroma: Double

    public init(lightness: Double = 1, chroma: Double = 1) {
        self.lightness = lightness
        self.chroma = chroma
    }

    public static let neutral = LabWeights()
}

/// CIE L*a*b* under a D65 white point.
///
/// SPEC § 5 asks for distance in Lab rather than RGB because RGB-near tiles are
/// often visibly wrong. The distance stays **CIE76**, plain Euclidean: CIEDE2000
/// is tuned for differences near the discrimination threshold while ours are
/// whole-photograph sized, and — the load-bearing reason — it is not a metric,
/// so it would close the door on any acceleration structure later.
public struct LabColor: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    // Exact rational constants, not their decimal roundings: 0.008856 and 903.3
    // are the usual approximations and they disagree with the inverse transform
    // just enough to fail a round-trip test near the knee.
    private static let epsilon = 216.0 / 24389.0   // (6/29)^3
    private static let kappa = 24389.0 / 27.0      // (29/3)^3

    // sRGB primaries to XYZ, D65. Given to full double precision so the round
    // trip through Lab is limited by the transfer function, not by the matrix.
    private static let whiteX = 0.950_455_927_051_671_6
    private static let whiteY = 1.0
    private static let whiteZ = 1.089_057_750_759_878_4

    public init(_ colour: LinearRGB) {
        let x = 0.412_390_799_265_959_5 * colour.r
            + 0.357_584_339_383_877_96 * colour.g
            + 0.180_480_788_401_834_3 * colour.b
        let y = 0.212_639_005_871_510_36 * colour.r
            + 0.715_168_678_767_755_9 * colour.g
            + 0.072_192_315_360_733_71 * colour.b
        let z = 0.019_330_818_715_591_851 * colour.r
            + 0.119_194_779_794_625_99 * colour.g
            + 0.950_532_152_249_660_6 * colour.b

        let fx = Self.f(x / Self.whiteX)
        let fy = Self.f(y / Self.whiteY)
        let fz = Self.f(z / Self.whiteZ)

        self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public init(srgb8 red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.init(LinearRGB(srgb8: red, green, blue))
    }

    /// The inverse, for tests and for anything that wants to show a Lab value.
    public var linear: LinearRGB {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200

        let x = Self.inverseF(fx) * Self.whiteX
        let y = Self.inverseF(fy) * Self.whiteY
        let z = Self.inverseF(fz) * Self.whiteZ

        return LinearRGB(
            r: 3.240_969_941_904_521_3 * x - 1.537_383_177_570_093_5 * y - 0.498_610_760_293_003_3 * z,
            g: -0.969_243_636_280_87 * x + 1.875_967_501_507_720_7 * y + 0.041_555_057_407_175_46 * z,
            b: 0.055_630_079_696_993_609 * x - 0.203_976_958_888_976_54 * y + 1.056_971_514_242_878_6 * z
        )
    }

    private static func f(_ t: Double) -> Double {
        t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
    }

    private static func inverseF(_ t: Double) -> Double {
        let cube = t * t * t
        return cube > epsilon ? cube : (116 * t - 16) / kappa
    }

    /// CIE76, optionally with the axes scaled. Still Euclidean, still a metric.
    public func deltaE(to other: LabColor, weights: LabWeights = .neutral) -> Double {
        sqrt(squaredDeltaE(to: other, weights: weights))
    }

    /// The same quantity without the square root, which is what a comparison
    /// wants: the solver runs this tens of millions of times per mosaic.
    public func squaredDeltaE(to other: LabColor, weights: LabWeights = .neutral) -> Double {
        let dl = (l - other.l) * weights.lightness
        let da = (a - other.a) * weights.chroma
        let db = (b - other.b) * weights.chroma
        return dl * dl + da * da + db * db
    }
}
