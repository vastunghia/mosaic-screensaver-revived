import CoreGraphics
import Foundation
import MosaicCore
import Testing
@testable import MosaicPhotos

@Suite("Canonical crop")
struct CanonicalCropTests {

    private func isCanonical(_ image: CGImage, _ label: Comment) {
        let expected = Double(image.height) * CanonicalAspect.ratio
        #expect(abs(Double(image.width) - expected) <= 1, label)
    }

    @Test("the crop is 16:9 whatever shape it came from")
    func aspectIsAlwaysCanonical() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let source = try FolderPhotoSource(root: folder.root)

        for name in ["%.jpg", "tall.jpg", "rotated.jpg", "a b  c.png"] {
            let image = try source.canonicalImage(for: PhotoID(name), maxPixelWidth: 256)
            isCanonical(image, "\(name) is not 16:9")
            #expect(image.width > image.height, "\(name) came back upright")
        }
    }

    @Test("max pixel width bounds the crop, not the original's longest side")
    func maxPixelWidthAppliesToTheCrop() throws {
        // The regression that matters. `kCGImageSourceThumbnailMaxPixelSize`
        // bounds the LONGEST side: asking a 1500x4000 photograph for 640 gives
        // back 240x640, whose 16:9 crop is 240x135 — a quarter of the resolution
        // asked for, on every portrait photograph in a library, and it looks like
        // a cropping bug rather than a flag.
        let folder = try HostileFolder()
        defer { folder.remove() }
        let source = try FolderPhotoSource(root: folder.root)

        let tall = try source.canonicalImage(for: PhotoID("tall.jpg"), maxPixelWidth: 640)
        #expect(tall.width == 640, "got \(tall.width)x\(tall.height)")
        #expect(tall.height == 360)

        // And it stays an upper bound: a source smaller than the request comes
        // back at its own size rather than blown up.
        let small = try source.canonicalImage(for: PhotoID("%.jpg"), maxPixelWidth: 4096)
        #expect(small.width <= 4096)
        isCanonical(small, "the small one lost its aspect")
    }

    @Test("EXIF orientation is applied, so a rotated portrait comes back landscape")
    func orientationIsApplied() throws {
        // rotated.jpg is stored 300x800 and tagged orientation 6, so it displays
        // as 800x300. Without the transform we would crop the stored pixels and
        // get a tall strip, plus a colour measured from the wrong part of the
        // photograph.
        let folder = try HostileFolder()
        defer { folder.remove() }
        let source = try FolderPhotoSource(root: folder.root)

        let image = try source.canonicalImage(for: PhotoID("rotated.jpg"), maxPixelWidth: 640)
        #expect(image.width > image.height)
        isCanonical(image, "the rotated one is not 16:9")
    }

    @Test("the crop rectangle is centred, and a 16:9 source keeps all of itself")
    func cropGeometry() {
        let exact = CanonicalCrop.rect(width: 1920, height: 1080)
        #expect(exact == CGRect(x: 0, y: 0, width: 1920, height: 1080))

        let tall = CanonicalCrop.rect(width: 1000, height: 4000)
        #expect(tall.width == 1000)
        #expect(tall.height == 563)
        #expect(tall.minX == 0)
        #expect(abs(tall.midY - 2000) <= 1, "the band has to be centred")

        let wide = CanonicalCrop.rect(width: 4000, height: 1000)
        #expect(wide.height == 1000)
        #expect(wide.width == 1778)
        #expect(abs(wide.midX - 2000) <= 1)
    }

    @Test("vertical photographs keep their middle, which is what closing § 8.2 chose")
    func portraitKeepsItsCentre() throws {
        // The fixture puts a red square in the middle of every image. After a
        // centre crop of a very tall photograph the red has to still be there:
        // that is the difference between cropping the centre and cropping a
        // corner, and it is invisible in any aspect-ratio assertion.
        let folder = try HostileFolder()
        defer { folder.remove() }
        let source = try FolderPhotoSource(root: folder.root)

        let image = try source.canonicalImage(for: PhotoID("tall.jpg"), maxPixelWidth: 160)
        let signature = try ImageSampling.signature(of: image, side: 1)
        #expect(signature.mean.r > signature.mean.g * 1.2, "the red middle is missing")
    }
}
