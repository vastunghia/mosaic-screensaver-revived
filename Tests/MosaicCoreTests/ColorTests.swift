import Foundation
import Testing
@testable import MosaicCore

@Suite("Colour")
struct ColorTests {
    @Test("the sRGB transfer function round trips at every 8-bit code")
    func transferRoundTrip() {
        for code in 0...255 {
            let encoded = Double(code) / 255
            let back = SRGBTransfer.encode(SRGBTransfer.decode(encoded))
            #expect(abs(back - encoded) < 1e-12, "code \(code)")
            #expect(abs(SRGBTransfer.decoded8[code] - SRGBTransfer.decode(encoded)) < 1e-15)
        }
    }

    @Test("white is L 100 and neutral, black is the origin")
    func extremes() {
        let white = LabColor(.white)
        #expect(abs(white.l - 100) < 1e-9)
        #expect(abs(white.a) < 1e-9)
        #expect(abs(white.b) < 1e-9)

        let black = LabColor(.black)
        #expect(abs(black.l) < 1e-9)
        #expect(abs(black.a) < 1e-9)
        #expect(abs(black.b) < 1e-9)
    }

    @Test("linear and Lab round trip, including across the epsilon/kappa knee")
    func labRoundTrip() {
        // The knee at t = 216/24389 is where the cube root gives way to the
        // linear segment. The decimal roundings of those constants that appear
        // in most references — 0.008856 and 903.3 — disagree with the inverse
        // transform just enough to fail here, which is why the source carries
        // the exact rationals.
        var samples: [LinearRGB] = []
        for t in stride(from: 0.0, through: 0.02, by: 0.000_5) {
            samples.append(LinearRGB(r: t, g: t, b: t))
        }
        for r in stride(from: 0.0, through: 1.0, by: 0.1) {
            for g in stride(from: 0.0, through: 1.0, by: 0.1) {
                for b in stride(from: 0.0, through: 1.0, by: 0.1) {
                    samples.append(LinearRGB(r: r, g: g, b: b))
                }
            }
        }

        for colour in samples {
            let back = LabColor(colour).linear
            #expect(abs(back.r - colour.r) < 1e-9, "r of \(colour)")
            #expect(abs(back.g - colour.g) < 1e-9, "g of \(colour)")
            #expect(abs(back.b - colour.b) < 1e-9, "b of \(colour)")
        }
    }

    @Test("lightness increases with the light, never the other way")
    func lightnessIsMonotonic() {
        var previous = -1.0
        for step in 0...200 {
            let value = Double(step) / 200
            let l = LabColor(LinearRGB(r: value, g: value, b: value)).l
            #expect(l > previous, "at \(value)")
            previous = l
        }
    }

    @Test("delta E is a metric, which is what licenses CIE76 here")
    func deltaEIsAMetric() {
        // Identity, symmetry and the triangle inequality are not pedantry: an
        // acceleration structure over the pool would need all three, and
        // CIEDE2000 has none of them. Giving them up is the cost of a more
        // perceptual formula, and this test is where that trade is recorded.
        var rng = SplitMix64(seed: 0xC01F)
        func sample() -> LabColor {
            LabColor(LinearRGB(r: rng.nextUnit(), g: rng.nextUnit(), b: rng.nextUnit()))
        }

        for _ in 0..<2000 {
            let x = sample(), y = sample(), z = sample()
            #expect(x.deltaE(to: x) == 0)
            #expect(abs(x.deltaE(to: y) - y.deltaE(to: x)) < 1e-12)
            #expect(x.deltaE(to: z) <= x.deltaE(to: y) + y.deltaE(to: z) + 1e-9)
        }
    }

    @Test("neutral weights are plain CIE76, and weighting stays Euclidean")
    func weights() {
        let x = LabColor(srgb8: 200, 30, 40)
        let y = LabColor(srgb8: 40, 90, 210)

        let plain = sqrt(
            pow(x.l - y.l, 2) + pow(x.a - y.a, 2) + pow(x.b - y.b, 2)
        )
        #expect(abs(x.deltaE(to: y) - plain) < 1e-12)

        // Scaling an axis scales that axis's contribution, and nothing else:
        // the distance is still a plain Euclidean one in rescaled coordinates.
        let weighted = x.deltaE(to: y, weights: LabWeights(lightness: 2, chroma: 0.5))
        let expected = sqrt(
            pow(2 * (x.l - y.l), 2) + pow(0.5 * (x.a - y.a), 2) + pow(0.5 * (x.b - y.b), 2)
        )
        #expect(abs(weighted - expected) < 1e-12)
    }

    @Test("averaging happens in linear light, and doing it in sRGB is wrong by sixty codes")
    func theLinearAveragingLaw() {
        // This test is a decision, written so it can fail. Half black and half
        // white has a mean of 0.5 of the light, which is sRGB code 188 — not
        // 127.5, which is what averaging gamma-encoded values gives and which
        // stands for 21.6% of the light. If anyone ever reverts to averaging
        // encoded values, or to averaging Lab, this says so by name.
        let mean = LinearRGB.mean(of: [LinearRGB.black, LinearRGB.white])
        #expect(abs(mean.r - 0.5) < 1e-15)

        let encoded = mean.srgb.r * 255
        #expect(abs(encoded - 188) < 1, "the true mean is code 188, got \(encoded)")
        #expect(abs(encoded - 127.5) > 55, "127.5 is the answer we must never produce")

        // And the same mistake one level up: the Lab of the mean is not the mean
        // of the Labs, so Lab values may never be averaged either.
        let labOfMean = LabColor(mean).l
        let meanOfLabs = (LabColor(.black).l + LabColor(.white).l) / 2
        #expect(abs(labOfMean - 76.07) < 0.01)
        #expect(labOfMean - meanOfLabs > 20)
    }
}
