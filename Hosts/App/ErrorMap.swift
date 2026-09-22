import Foundation

/// Where a mosaic is wrong, as a picture the size of the mosaic.
///
/// Each cell is filled with its delta E on a single-hue ramp, light for a close
/// tile and dark for a bad one. The scale is fixed rather than stretched to each
/// mosaic's own worst cell: two maps are only comparable if the same shade means
/// the same error in both, and comparing them is what the map is for.
enum ErrorMap {
    /// Everything at or above this is drawn at the darkest step. The worst cells
    /// seen on a real corpus sit around 35–45; a ceiling well above that would
    /// spend the ramp on values that never occur.
    static let ceiling = 40.0

    /// A blue ramp, light to dark, as sRGB bytes. Sequential data wants one
    /// hue: a rainbow would invent boundaries the error does not have.
    private static let ramp: [(UInt8, UInt8, UInt8)] = [
        (0xCD, 0xE2, 0xFB),
        (0x9E, 0xC5, 0xF4),
        (0x6D, 0xA7, 0xEC),
        (0x39, 0x87, 0xE5),
        (0x25, 0x6A, 0xBF),
        (0x18, 0x4F, 0x95),
        (0x0D, 0x36, 0x6B),
    ]

    /// The ramp's stops as CSS colours, for the legend of the batch page.
    static var cssStops: [String] {
        ramp.map { String(format: "#%02x%02x%02x", $0.0, $0.1, $0.2) }
    }

    static func write(cellDeltaE: [Double], rows: Int, width: Int, height: Int, to url: URL) throws {
        precondition(cellDeltaE.count == rows * rows, "one delta E per cell")
        let colours = cellDeltaE.map(colour)

        // BGRA, to match what PNGWriter expects from a texture readback.
        var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
        for y in 0..<height {
            let row = y * rows / height
            for x in 0..<width {
                let (r, g, b) = colours[row * rows + x * rows / width]
                let offset = (y * width + x) * 4
                pixels[offset] = b
                pixels[offset + 1] = g
                pixels[offset + 2] = r
            }
        }
        try PNGWriter.write(pixels: pixels, width: width, height: height, to: url)
    }

    private static func colour(_ deltaE: Double) -> (UInt8, UInt8, UInt8) {
        let position = min(max(deltaE / ceiling, 0), 1) * Double(ramp.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, ramp.count - 1)
        let t = position - Double(lower)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) * (1 - t) + Double(b) * t).rounded())
        }
        let (a, b) = (ramp[lower], ramp[upper])
        return (mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
    }
}
