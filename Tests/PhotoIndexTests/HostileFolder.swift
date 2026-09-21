import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A folder of photographs with names chosen to break things.
///
/// It is **built at test time**, in a directory of its own, rather than checked
/// into the repository. Three reasons, all of which have bitten someone: git and
/// Unicode normalisation disagree about file names, swift-testing runs suites in
/// parallel so a shared fixture is a shared mutable, and a test that writes the
/// files states what it is testing instead of hiding it in a tree.
struct HostileFolder {
    let root: URL

    /// Names that are real, readable images. The rest of the tree is traps.
    static let images = [
        "%.jpg",
        "$ #@.jpeg",
        "UPPER.JPG",
        "Ünïcødé.jpg",
        "a b  c.png",
        "line\nbreak.jpg",
        "-.jpg",
        "50% off/%.jpg",
        "50% off/nested/deep.jpg",
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-hostile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (index, name) in Self.images.enumerated() {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.write(
                width: 320 + index * 8, height: 180 + index * 4,
                to: url, type: name.hasSuffix(".png") ? .png : .jpeg
            )
        }

        // Traps.
        try Self.write(width: 64, height: 36, to: root.appendingPathComponent(".hidden.jpg"), type: .jpeg)
        try Self.write(width: 64, height: 36, to: root.appendingPathComponent("._sidecar.jpg"), type: .jpeg)
        try Self.write(width: 64, height: 36, to: root.appendingPathComponent("actually-an-image.txt"), type: .jpeg)
        try Data().write(to: root.appendingPathComponent("empty.jpg"))
        try Data("not an image at all".utf8).write(to: root.appendingPathComponent("actually-text.jpg"))

        // A package directory, which is what a Photos library looks like.
        let package = root.appendingPathComponent("Album.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Self.write(width: 64, height: 36, to: package.appendingPathComponent("inside.jpg"), type: .jpeg)

        // A very tall photograph, for the thumbnail-sizing regression.
        try Self.write(width: 1500, height: 4000, to: root.appendingPathComponent("tall.jpg"), type: .jpeg)

        // And one tagged EXIF orientation 6: stored portrait, displayed landscape.
        try Self.write(
            width: 300, height: 800,
            to: root.appendingPathComponent("rotated.jpg"), type: .jpeg, orientation: 6
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every file in the tree that a source is expected to enumerate.
    static var expectedIdentifiers: Set<String> {
        Set(images + ["actually-text.jpg", "empty.jpg", "tall.jpg", "rotated.jpg"])
    }

    static func write(
        width: Int, height: Int, to url: URL, type: UTType, orientation: Int? = nil
    ) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // A distinctive band down the middle, so a crop can be recognised.
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(
            x: Double(width) * 0.4, y: Double(height) * 0.4,
            width: Double(width) * 0.2, height: Double(height) * 0.2
        ))
        let image = context.makeImage()!

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
