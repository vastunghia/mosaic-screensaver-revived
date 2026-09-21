import CoreGraphics
import Foundation
import ImageIO
import MosaicCore

public enum CanonicalCropError: Error, CustomStringConvertible {
    case couldNotOpen(URL)
    case couldNotDecode(URL)
    case couldNotCrop
    case couldNotDraw

    public var description: String {
        switch self {
        case .couldNotOpen(let url): return "could not open \(url.lastPathComponent)"
        case .couldNotDecode(let url): return "could not decode \(url.lastPathComponent)"
        case .couldNotCrop: return "could not take the canonical crop"
        case .couldNotDraw: return "could not draw the canonical crop"
        }
    }
}

/// The one path from a file on disk to the 16:9 image everything else works on.
///
/// Every photograph has a single canonical crop (SPEC § 4), because it appears
/// both as a tile and full screen and the two have the same aspect ratio. Taking
/// it in one place matters more than it looks: the index, the atlas and the
/// solver all have to agree on what "this photograph's colour" means, and they
/// only do if they are all looking at the same pixels.
///
/// Vertical photographs are **centre cropped** (SPEC § 4, question 8.2, closed).
/// The alternative — letterboxing them inside a 16:9 box — would introduce a
/// band whose colour the solver would then match on, which is choosing tiles
/// partly on the strength of a colour the program invented. SPEC § 2 forbids
/// exactly that.
public enum CanonicalCrop {
    /// The centred 16:9 rectangle inside a `width × height` image.
    public static func rect(width: Int, height: Int) -> CGRect {
        precondition(width > 0 && height > 0)
        let wide = Double(width) / Double(height) > CanonicalAspect.ratio
        let cropWidth = wide ? Double(height) * CanonicalAspect.ratio : Double(width)
        let cropHeight = wide ? Double(height) : Double(width) / CanonicalAspect.ratio

        // Integral, because CGImage.cropping rounds and a half-pixel of drift
        // between two calls would make the same photograph two colours.
        let w = min(width, Int(cropWidth.rounded()))
        let h = min(height, Int(cropHeight.rounded()))
        return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }

    /// The canonical crop of a file, at most `maxPixelWidth` across.
    public static func image(at url: URL, maxPixelWidth: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CanonicalCropError.couldNotOpen(url)
        }
        return try image(from: source, url: url, maxPixelWidth: maxPixelWidth)
    }

    public static func image(from source: CGImageSource, url: URL, maxPixelWidth: Int) throws -> CGImage {
        precondition(maxPixelWidth > 0)

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1

        var options: [CFString: Any] = [
            // NOT `...FromImageIfAbsent`. "IfAbsent" prefers an embedded EXIF
            // thumbnail when there is one, and nearly every JPEG and every HEIC
            // off a phone has one at around 160x120. The index would then be
            // built from postage stamps while believing it had 640x360 crops.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so what comes back is upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            // `kCGImageSourceThumbnailMaxPixelSize` bounds the **longest** side,
            // not the width. Asking for 640 on a portrait photograph yields
            // 360x640, whose 16:9 crop is 360x203 — a soft tile, and one that
            // would be blamed on the cropping rather than on this flag. So the
            // bound is worked out from the crop we are actually going to keep.
            let upright = (5...8).contains(orientation)
            let width = upright ? pixelHeight : pixelWidth
            let height = upright ? pixelWidth : pixelHeight
            let crop = rect(width: width, height: height)
            let scale = Double(maxPixelWidth) / Double(crop.width)
            let longest = Double(max(width, height)) * scale
            options[kCGImageSourceThumbnailMaxPixelSize] = max(1, Int(longest.rounded(.up)))
        } else {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelWidth
        }

        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CanonicalCropError.couldNotDecode(url)
        }
        return try image(decoded, maxPixelWidth: maxPixelWidth)
    }

    /// The canonical crop of an image already in memory, redrawn into sRGB.
    ///
    /// The redraw is not waste: it is what makes Display P3, Adobe RGB, grey,
    /// CMYK and 16-bit sources all mean the same thing downstream.
    public static func image(_ image: CGImage, maxPixelWidth: Int) throws -> CGImage {
        let crop = rect(width: image.width, height: image.height)
        guard let cropped = image.cropping(to: crop) else {
            throw CanonicalCropError.couldNotCrop
        }

        let width = max(1, min(maxPixelWidth, cropped.width))
        let height = CanonicalAspect.height(forWidth: width)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CanonicalCropError.couldNotDraw
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let result = context.makeImage() else {
            throw CanonicalCropError.couldNotDraw
        }
        return result
    }
}
