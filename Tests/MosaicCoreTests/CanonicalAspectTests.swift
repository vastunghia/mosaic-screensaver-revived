import Foundation
import Testing
@testable import MosaicCore

@Suite("Canonical aspect on screens of other shapes")
struct CanonicalAspectTests {
    /// A 16:9 tile drawn with these spans keeps its shape: on screen its width
    /// over its height is 16:9 whatever the viewport.
    private func onScreenAspect(viewportWidth w: Double, height h: Double) -> Double {
        let fill = CanonicalAspect.fill(viewportWidth: w, height: h)
        // Mosaic space is square: a cell is 1/R wide and 1/R tall, and the
        // camera spans fill.x across the width and fill.y down the height.
        let pixelsAcross = w / fill.x
        let pixelsDown = h / fill.y
        return pixelsAcross / pixelsDown
    }

    @Test("16:9 shows everything, within a pixel too", arguments: [
        (2560.0, 1440.0), (1920, 1080), (854, 480), (1280, 720), (3840, 2160),
    ])
    func sixteenByNine(size: (Double, Double)) {
        let fill = CanonicalAspect.fill(viewportWidth: size.0, height: size.1)
        #expect(fill.x == 1 && fill.y == 1)
        #expect(CanonicalAspect.filledWidth(viewportWidth: size.0, height: size.1) >= size.0)
    }

    @Test("a narrower screen crops the sides", arguments: [
        (2560.0, 1664.0), (2560, 1600), (1024, 768), (1080, 1920),
    ])
    func narrower(size: (Double, Double)) {
        let fill = CanonicalAspect.fill(viewportWidth: size.0, height: size.1)
        #expect(fill.y == 1)
        #expect(fill.x < 1)
        #expect(abs(fill.x - (size.0 / size.1) / CanonicalAspect.ratio) < 1e-12)
        #expect(abs(onScreenAspect(viewportWidth: size.0, height: size.1) - CanonicalAspect.ratio) < 1e-9)
        #expect(abs(CanonicalAspect.filledWidth(viewportWidth: size.0, height: size.1) - size.1 * 16 / 9) < 1e-9)
    }

    @Test("a wider screen crops top and bottom", arguments: [(3440.0, 1440.0), (5120, 1440)])
    func wider(size: (Double, Double)) {
        let fill = CanonicalAspect.fill(viewportWidth: size.0, height: size.1)
        #expect(fill.x == 1)
        #expect(fill.y < 1)
        #expect(abs(onScreenAspect(viewportWidth: size.0, height: size.1) - CanonicalAspect.ratio) < 1e-9)
        #expect(CanonicalAspect.filledWidth(viewportWidth: size.0, height: size.1) == size.0)
    }

    @Test("a 13-inch laptop at its default scaling keeps 87 % of the width")
    func laptop() {
        let fill = CanonicalAspect.fill(viewportWidth: 2560, height: 1664)
        #expect(abs(fill.x - 0.8654) < 1e-3)
    }

    @Test("no size gives the whole view")
    func empty() {
        let fill = CanonicalAspect.fill(viewportWidth: 0, height: 0)
        #expect(fill.x == 1 && fill.y == 1)
    }
}
