import CoreGraphics
import Foundation
import MosaicCore
import Testing
@testable import MosaicPhotos

@Suite("Image sampling")
struct ImageSamplingTests {

    private func image(width: Int, height: Int, fill: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        fill(context)
        return context.makeImage()!
    }

    @Test("half black and half white averages to half the light, not to mid grey")
    func averagingHappensInLinearLight() throws {
        // The whole reason ImageSampling does its own reduction instead of
        // handing CGContext a 1x1 destination. CGContext averages in sRGB, which
        // would give 0.216 of the light here — sixty codes too dark — and every
        // high-contrast photograph in the pool would be matched as if it were
        // much darker than it looks.
        let split = image(width: 64, height: 36) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 36))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 36))
        }

        let mean = try ImageSampling.signature(of: split, side: 1).mean
        #expect(abs(mean.r - 0.5) < 1e-6, "got \(mean.r)")
        #expect(abs(mean.r - 0.2140) > 0.2, "0.214 is the sRGB-averaged answer")
    }

    @Test("a flat image samples to its own colour, at every detail")
    func flatImages() throws {
        let grey = image(width: 80, height: 45) { context in
            context.setFillColor(CGColor(srgbRed: 0.4, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 45))
        }
        let expected = LinearRGB(srgb: 0.4, 0.6, 0.8)

        for side in [1, 2, 4, 8] {
            let signature = try ImageSampling.signature(of: grey, side: side)
            for cell in signature.cells {
                #expect(abs(cell.r - expected.r) < 0.01, "side \(side)")
                #expect(abs(cell.g - expected.g) < 0.01, "side \(side)")
                #expect(abs(cell.b - expected.b) < 0.01, "side \(side)")
            }
        }
    }

    @Test("a signature knows which half is which, and the halves agree with the whole")
    func spatialLayout() throws {
        let split = image(width: 64, height: 36) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            // CGContext draws bottom-up, so this paints the TOP half white.
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 18, width: 64, height: 18))
        }

        let signature = try ImageSampling.signature(of: split, side: 2)
        #expect(signature[0, 0].r > 0.9, "the top row has to be the light one")
        #expect(signature[1, 0].r > 0.9)
        #expect(signature[0, 1].r < 0.1, "the bottom row has to be the dark one")
        #expect(signature[1, 1].r < 0.1)

        // And reducing the signature agrees with sampling straight to 1x1,
        // which is what makes the stored 4x4 usable as an average colour.
        let direct = try ImageSampling.signature(of: split, side: 1).mean
        let reduced = signature.reduced(to: 1).mean
        #expect(abs(direct.r - reduced.r) < 1e-9)
    }

    @Test("cell boundaries that fall between pixels are split by area, not rounded")
    func areaWeighting() throws {
        // 10 pixels over 3 cells is 3.33 each, so two boundaries land inside a
        // pixel. Rounding them to one side would bias every cell the same way
        // and show up as a grid of its own on a smooth photograph.
        let ramp = image(width: 10, height: 10) { context in
            for x in 0..<10 {
                let value = Double(x) / 9
                context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 10))
            }
        }

        // The expectation comes from the pixels the context actually holds, not
        // from the floats the fixture asked for: an 8-bit context quantises, and
        // testing against the un-quantised ideal would be testing the fixture.
        let samples = try ImageSampling.samples(of: ramp)
        let expected = stride(from: 0, to: samples.bytes.count, by: 4)
            .map { SRGBTransfer.decoded8[Int(samples.bytes[$0])] }
            .reduce(0, +) / Double(samples.width * samples.height)

        let whole = try ImageSampling.signature(of: ramp, side: 1).mean.r
        #expect(abs(whole - expected) < 1e-12, "got \(whole), expected \(expected)")

        let thirds = ImageSampling.reduce(samples, columns: 3, rows: 1)
        #expect(thirds[0].r < thirds[1].r)
        #expect(thirds[1].r < thirds[2].r)
        let mean = (thirds[0].r + thirds[1].r + thirds[2].r) / 3
        #expect(abs(mean - whole) < 1e-12, "the parts have to add back up to the whole")
    }

    @Test("a target grid is R by k cells across the crop")
    func targetGridShape() throws {
        let flat = image(width: 640, height: 360) { context in
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }

        for rows in [30, 60, 90] {
            for detail in [1, 2, 4] {
                let grid = try ImageSampling.targetGrid(of: flat, rows: rows, detail: detail)
                #expect(grid.cells.count == (rows * detail) * (rows * detail))
                #expect(grid.signature(of: GridCell(column: 0, row: 0)).side == detail)
            }
        }
    }
}
