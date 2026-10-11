import CoreGraphics
import MosaicCore
import MosaicPhotos
import MosaicPhotoKit
import Testing

/// The size asked of PhotoKit, which has to make the *crop* the requested
/// width — plus one pixel, because PhotoKit rounds down. What PhotoKit then
/// delivers needs a library and is checked by the harness
/// (`--verify-canonical`), not here.
struct TargetSizeTests {
    private func cropWidth(of size: CGSize) -> Int {
        Int(CanonicalCrop.rect(width: Int(size.width), height: Int(size.height)).width)
    }

    @Test func landscapeAtTheCanonicalAspectIsScaledToOnePixelMore() {
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 3840, pixelHeight: 2160, cropWidth: 854)
        #expect(size.width == 855)
        #expect(cropWidth(of: size) == 855)
    }

    @Test func aPortraitIsScaledByItsCropNotItsLongestSide() {
        // 3000x4000: the crop is 3000 wide, so the scale is 855/3000.
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 3000, pixelHeight: 4000, cropWidth: 854)
        #expect(size.width == 855)
        #expect(cropWidth(of: size) == 855)
    }

    @Test func aPanoramaIsScaledByItsCropToo() {
        // 12000x2000: the crop is 3556x2000.
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 12000, pixelHeight: 2000, cropWidth: 854)
        #expect(abs(cropWidth(of: size) - 855) <= 1)
    }

    @Test func aSmallPhotographIsNeverScaledUp() {
        let size = PhotoKitPhotoSource.targetSize(pixelWidth: 640, pixelHeight: 480, cropWidth: 854)
        #expect(size == CGSize(width: 640, height: 480))
        let exact = PhotoKitPhotoSource.targetSize(pixelWidth: 854, pixelHeight: 480, cropWidth: 854)
        #expect(exact == CGSize(width: 854, height: 480))
    }

    @Test func aPhotographOfUnknownSizeNeedsTheWholeWidth() {
        #expect(PhotoKitPhotoSource.neededCropWidth(pixelWidth: 0, pixelHeight: 0, cropWidth: 854) == 854)
        #expect(PhotoKitPhotoSource.neededCropWidth(pixelWidth: 3840, pixelHeight: 2160, cropWidth: 854) == 854)
        #expect(PhotoKitPhotoSource.neededCropWidth(pixelWidth: 350, pixelHeight: 233, cropWidth: 854) == 350)
    }
}
