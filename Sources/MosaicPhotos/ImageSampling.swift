import CoreGraphics
import Foundation
import MosaicCore

public enum ImageSamplingError: Error {
    case couldNotReadPixels
}

/// Where pixels become the colours the solver reasons about.
///
/// Every average here is taken **in linear light**, on purpose and at some cost:
/// it would be a couple of lines to hand a `CGContext` a 4x4 destination and let
/// it resample, and it would be wrong. `CGContext` averages in its own colour
/// space, which is gamma-encoded sRGB, and averaging encoded values makes a
/// half-black half-white photograph come out at 21.6% of the light instead of
/// 50% — sixty codes too dark, worst on exactly the high-contrast photographs a
/// mosaic is mostly made of. See `LinearRGB`.
public enum ImageSampling {
    /// A `k × k` signature of an image that is already the canonical crop.
    public static func signature(of image: CGImage, side: Int) throws -> TileSignature {
        let pixels = try samples(of: image)
        return TileSignature(
            side: side,
            cells: reduce(pixels, columns: side, rows: side)
        )
    }

    /// The target grid of SPEC § 5 step 2: `R · k` cells across the canonical
    /// crop, each an area mean in linear light.
    public static func targetGrid(of image: CGImage, rows: Int, detail: Int) throws -> TargetGrid {
        let pixels = try samples(of: image)
        let side = rows * detail
        return TargetGrid(
            rows: rows,
            detail: detail,
            cells: reduce(pixels, columns: side, rows: side)
        )
    }

    struct Samples {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    /// The image as straight sRGB bytes, top row first.
    static func samples(of image: CGImage) throws -> Samples {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // No flip. A bitmap context's first row of memory is the top of the
            // image, and `draw` puts the CGImage's first row there, so row 0 of
            // `bytes` is already row 0 of the photograph. Flipping here — which
            // looks right, because the user-space origin is at the bottom left —
            // turns every signature upside down, and nothing about a colour
            // average shows it.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ImageSamplingError.couldNotReadPixels }
        return Samples(bytes: bytes, width: width, height: height)
    }

    /// An area-weighted box reduction. Cell boundaries almost never land on
    /// pixel boundaries — 640 pixels over 60 cells is 10.67 each — so the edge
    /// pixels are split by area rather than rounded to one side, which would
    /// bias every cell the same way and show as a grid of its own.
    static func reduce(_ samples: Samples, columns: Int, rows: Int) -> [LinearRGB] {
        let lut = SRGBTransfer.decoded8
        let width = samples.width
        let height = samples.height
        var cells = [LinearRGB](repeating: .black, count: columns * rows)

        let columnSpan = Double(width) / Double(columns)
        let rowSpan = Double(height) / Double(rows)

        samples.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<rows {
                let yStart = Double(row) * rowSpan
                let yEnd = yStart + rowSpan
                let firstY = Int(yStart)
                let lastY = min(height - 1, Int((yEnd - 1e-9).rounded(.down)))

                for column in 0..<columns {
                    let xStart = Double(column) * columnSpan
                    let xEnd = xStart + columnSpan
                    let firstX = Int(xStart)
                    let lastX = min(width - 1, Int((xEnd - 1e-9).rounded(.down)))

                    var r = 0.0, g = 0.0, b = 0.0, total = 0.0

                    for y in firstY...lastY {
                        let yWeight = min(Double(y + 1), yEnd) - max(Double(y), yStart)
                        if yWeight <= 0 { continue }
                        let rowBase = y * width * 4

                        for x in firstX...lastX {
                            let xWeight = min(Double(x + 1), xEnd) - max(Double(x), xStart)
                            if xWeight <= 0 { continue }
                            let weight = xWeight * yWeight
                            let base = rowBase + x * 4
                            r += lut[Int(bytes[base])] * weight
                            g += lut[Int(bytes[base + 1])] * weight
                            b += lut[Int(bytes[base + 2])] * weight
                            total += weight
                        }
                    }

                    if total > 0 {
                        cells[row * columns + column] = LinearRGB(
                            r: r / total, g: g / total, b: b / total
                        )
                    }
                }
            }
        }
        return cells
    }
}
