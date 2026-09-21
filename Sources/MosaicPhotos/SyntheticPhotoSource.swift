import CoreGraphics
import Foundation
import MosaicCore

/// Photographs that do not exist, generated on demand.
///
/// This is what milestone 1 runs on: it lets the movement be judged before
/// there is any indexing, any PhotoKit, or any decision about which photographs
/// to use.
///
/// The images are deliberately **band-limited** — smooth gradients and soft
/// blobs, nothing with a hard edge. One tile has to stretch across the whole
/// screen at the start of every cycle, and sharp synthetic content would break
/// up into artefacts that belong to the test data rather than to the effect,
/// polluting the one judgement this milestone exists to make.
public struct SyntheticPhotoSource: PhotoSource {
    public let count: Int

    public init(count: Int = 256) {
        precondition(count > 0)
        self.count = count
    }

    public func photos() throws -> [PhotoDescriptor] {
        (0..<count).map {
            PhotoDescriptor(id: SyntheticPhotoSource.id(for: $0), versionToken: "synthetic-1")
        }
    }

    public static func id(for index: Int) -> PhotoID {
        PhotoID(String(format: "synthetic:%05d", index))
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        guard let index = Self.index(of: id), index < count else {
            throw PhotoSourceError.unknownPhoto(id)
        }

        // 16:9, the canonical crop of SPEC § 4. These photographs have no
        // original to crop from: they are generated at the canonical aspect.
        let width = max(CanonicalAspect.width, maxPixelWidth)
        let height = CanonicalAspect.height(forWidth: width)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PhotoSourceError.couldNotRender(id)
        }

        var rng = SplitMix64(seed: UInt64(index) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678)
        draw(into: context, width: width, height: height, rng: &rng)

        guard let image = context.makeImage() else {
            throw PhotoSourceError.couldNotRender(id)
        }
        return image
    }

    private func draw(into context: CGContext, width: Int, height: Int, rng: inout SplitMix64) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        // A two-stop gradient across a random direction gives the tile its
        // average colour, which is what the mosaic solver will one day match on.
        let hue = rng.nextUnit()
        let base = Self.color(hue: hue, saturation: 0.45 + 0.4 * rng.nextUnit(), brightness: 0.35 + 0.5 * rng.nextUnit())
        let away = Self.color(hue: (hue + 0.08 + 0.12 * rng.nextUnit()).truncatingRemainder(dividingBy: 1),
                              saturation: 0.35 + 0.4 * rng.nextUnit(),
                              brightness: 0.30 + 0.55 * rng.nextUnit())

        if let gradient = CGGradient(colorsSpace: space, colors: [base, away] as CFArray, locations: [0, 1]) {
            let angle = rng.nextUnit() * 2 * .pi
            let radius = Double(max(width, height))
            let center = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: center.x - cos(angle) * radius / 2, y: center.y - sin(angle) * radius / 2),
                end: CGPoint(x: center.x + cos(angle) * radius / 2, y: center.y + sin(angle) * radius / 2),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Two or three soft blobs, so a photograph seen full-screen has some
        // structure to it and the crossfade out of its own mosaic is visible.
        for _ in 0..<(2 + Int(rng.nextUnit() * 2)) {
            let blobHue = (hue + 0.5 + 0.3 * (rng.nextUnit() - 0.5)).truncatingRemainder(dividingBy: 1)
            let inner = Self.color(hue: blobHue, saturation: 0.5, brightness: 0.85, alpha: 0.55)
            let outer = Self.color(hue: blobHue, saturation: 0.5, brightness: 0.85, alpha: 0)
            guard let blob = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else {
                continue
            }
            let center = CGPoint(x: rng.nextUnit() * Double(width), y: rng.nextUnit() * Double(height))
            let r = (0.25 + 0.45 * rng.nextUnit()) * Double(min(width, height))
            context.drawRadialGradient(
                blob,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: r,
                options: []
            )
        }

        _ = rect
    }

    private static func index(of id: PhotoID) -> Int? {
        guard id.rawValue.hasPrefix("synthetic:") else { return nil }
        return Int(id.rawValue.dropFirst("synthetic:".count))
    }

    private static func color(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) -> CGColor {
        let (r, g, b) = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    private static func hsbToRGB(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
