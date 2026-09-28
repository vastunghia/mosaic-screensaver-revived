import CoreGraphics
import MosaicCore
import MosaicPhotos
import MosaicPhotoKit
import Testing

/// The size asked of PhotoKit, which has to make the *crop* the requested
/// width. What PhotoKit then delivers needs a library and is checked by the
/// harness (`--verify-canonical`), not here.
struct TargetSizeTests {
    @Test func landscapeAtTheCanonicalAspectIsScaledToTheWidth() {
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 3840, pixelHeight: 2160, cropWidth: 854)
        #expect(size.width == 854)
        #expect(size.height == 481) // 480.375, rounded up
    }

    @Test func aPortraitIsScaledByItsCropNotItsLongestSide() {
        // 3000x4000: the crop is 3000x1688, so the scale is 854/3000.
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 3000, pixelHeight: 4000, cropWidth: 854)
        #expect(size.width == 854)
        #expect(size.height == 1139)
        let crop = CanonicalCrop.rect(width: Int(size.width), height: Int(size.height))
        #expect(crop.width == 854)
    }

    @Test func aPanoramaIsScaledByItsCropToo() {
        // 12000x2000: the crop is 3556x2000.
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 12000, pixelHeight: 2000, cropWidth: 854)
        let crop = CanonicalCrop.rect(width: Int(size.width), height: Int(size.height))
        #expect(abs(Int(crop.width) - 854) <= 1)
    }

    @Test func aSmallPhotographIsNeverScaledUp() {
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 640, pixelHeight: 480, cropWidth: 854)
        #expect(size == CGSize(width: 640, height: 480))
    }
}
