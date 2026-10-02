import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Testing
@testable import PhotoIndex

/// A tall photograph, red above and blue below, standing in for an original:
/// where a crop was cut from it shows in the colour of its last row.
private struct BandsSource: PhotoSource {
    static let id = PhotoID("bands")

    func photos() throws -> [PhotoDescriptor] {
        [PhotoDescriptor(id: Self.id, versionToken: "1")]
    }

    func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage {
        let width = 90, height = 320
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // The context draws from the bottom: blue is the lower half.
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        try CanonicalCrop.image(uprightImage(for: id, cropWidth: maxPixelWidth), maxPixelWidth: maxPixelWidth)
    }
}

@Suite("Crop window in the index")
struct CropWindowIndexTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-window-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Red and blue of the bottom row's middle pixel.
    private func bottomRow(_ image: CGImage) -> (red: UInt8, blue: UInt8) {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        // The first row in memory is the top of the image, so the bottom is the last.
        let offset = (image.height - 1) * image.width * 4 + image.width / 2 * 4
        return (pixels[offset], pixels[offset + 2])
    }

    private func index(cropStart: Double?) -> IndexedPhotoSource {
        let entry = IndexEntry(
            id: BandsSource.id.rawValue, versionToken: "1", thumbnail: "thumbs/none.jpg",
            signature: TileSignature(side: 1, cells: [LinearRGB(r: 0, g: 0, b: 0)]),
            pixelWidth: 32, pixelHeight: 18, cropStart: cropStart
        )
        let manifest = IndexManifest(
            root: "bands", thumbnailWidth: 32, thumbnailHeight: 18, signatureSide: 1, entries: [entry]
        )
        return IndexedPhotoSource(
            store: PhotoIndexStore(directory: temporaryDirectory()), manifest: manifest, originals: BandsSource()
        )
    }

    @Test("a close-up from the originals is cut where the index put the window")
    func closeUpsFollowTheWindow() throws {
        // Centred, the 90x51 window straddles the middle: its last row is blue.
        let centred = try index(cropStart: nil).canonicalImage(for: BandsSource.id, maxPixelWidth: 64)
        #expect(bottomRow(centred).blue > 200)

        // At the top, it is all red — the window of the index, not the centre.
        let top = try index(cropStart: 0).canonicalImage(for: BandsSource.id, maxPixelWidth: 64)
        #expect(bottomRow(top).red > 200 && bottomRow(top).blue < 50)
        #expect(abs(Double(top.width) / Double(top.height) - CanonicalAspect.ratio) < 0.05)
    }

    @Test("an index built with another crop rule, or before there were rules, is rebuilt")
    func cropRuleInvalidates() throws {
        let manifest = IndexManifest(
            root: "/x", thumbnailWidth: 128, thumbnailHeight: 72, signatureSide: 4, cropRule: .centre
        )
        #expect(manifest.matches(root: "/x", thumbnailWidth: 128, signatureSide: 4, cropRule: .centre))
        #expect(!manifest.matches(root: "/x", thumbnailWidth: 128, signatureSide: 4, cropRule: .faces))

        // A format-1 manifest: no cropRule at all. It still decodes — it is
        // turned away, not thrown at.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        old["formatVersion"] = 1
        old.removeValue(forKey: "cropRule")
        let decoded = try JSONDecoder().decode(
            IndexManifest.self, from: JSONSerialization.data(withJSONObject: old)
        )
        #expect(!decoded.matches(root: "/x", thumbnailWidth: 128, signatureSide: 4))
    }

    @Test("without faces, the face-aware build cuts exactly what the centre crop did")
    func facelessPhotographsAreUnchanged() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let source = try FolderPhotoSource(root: folder.root)

        var signatures: [CropRule: [String: Data]] = [:]
        for rule in CropRule.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let manifest = try PhotoIndexBuilder(thumbnailWidth: 128, signatureSide: 4, cropRule: rule)
                .build(from: source, into: PhotoIndexStore(directory: directory), root: folder.root.path)
            #expect(manifest.cropRule == rule)
            #expect(manifest.entries.allSatisfy { $0.cropStart == nil }, "a face found in a synthetic image")
            signatures[rule] = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0.signature) })
        }
        #expect(signatures[.centre] == signatures[.faces])
    }

    @Test("the window survives the manifest, and a centred one is not written at all")
    func cropStartRoundTrips() throws {
        let entries = [nil, 0.25].map { start in
            IndexEntry(
                id: "a", versionToken: "1", thumbnail: "t",
                signature: TileSignature(side: 1, cells: [LinearRGB(r: 0, g: 0, b: 0)]),
                pixelWidth: 1, pixelHeight: 1, cropStart: start
            )
        }
        for entry in entries {
            let data = try JSONEncoder().encode(entry)
            #expect(try JSONDecoder().decode(IndexEntry.self, from: data) == entry)
            #expect(String(decoding: data, as: UTF8.self).contains("cropStart") == (entry.cropStart != nil))
        }
    }
}
