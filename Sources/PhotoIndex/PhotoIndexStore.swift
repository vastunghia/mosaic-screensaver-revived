import CoreGraphics
import Foundation
import ImageIO
import MosaicCore
import UniformTypeIdentifiers

public enum PhotoIndexError: Error, CustomStringConvertible {
    case rootMismatch(stored: String, wanted: String)
    case couldNotWriteThumbnail(String)
    case couldNotReadThumbnail(String)
    case missing(URL)

    public var description: String {
        switch self {
        case .rootMismatch(let stored, let wanted):
            return "this index was built for \(stored), not for \(wanted)"
        case .couldNotWriteThumbnail(let name): return "could not write \(name)"
        case .couldNotReadThumbnail(let name): return "could not read \(name)"
        case .missing(let url): return "no index at \(url.path)"
        }
    }
}

/// The index directory, as a thing that can be read and written.
///
/// It lives wherever the host says. In production that is
/// `~/Library/Application Support/Mosaic/`, because spike 2 showed the saver can
/// read outside its container but not write there: the app writes at home and
/// the saver reads from it. The store knows nothing about that arrangement —
/// it takes a URL.
public struct PhotoIndexStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    public func url(forThumbnail name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// The manifest, or nil when there is none or it is from another format.
    /// A damaged or half-written file reads as "no index", never as a crash.
    public func load() throws -> IndexManifest? {
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { return nil }
        guard let manifest = try? JSONDecoder().decode(IndexManifest.self, from: data) else {
            return nil
        }
        guard manifest.formatVersion == IndexManifest.currentFormatVersion else { return nil }
        return manifest
    }

    /// Replaces the manifest atomically: a temporary file and a rename, which is
    /// what `Data.write(options: .atomic)` does. There is no lock between the app
    /// and the saver, and the app may rewrite the index while the saver is
    /// reading it, so a reader must only ever see a whole manifest — the old one
    /// or the new one.
    public func save(_ manifest: IndexManifest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sorted = manifest
        sorted.entries.sort { $0.id < $1.id }
        sorted.skipped.sort()
        sorted.unavailable.sort()
        sorted.belowFullScreen.sort()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sorted).write(to: manifestURL, options: .atomic)
    }

    public func writeThumbnail(_ image: CGImage, named name: String) throws {
        let url = url(forThumbnail: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw PhotoIndexError.couldNotWriteThumbnail(name)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoIndexError.couldNotWriteThumbnail(name)
        }
    }

    /// The thumbnail, at most `maxPixelWidth` across.
    ///
    /// Asked for less than is stored — the atlas wants 256 of 854 — the JPEG is
    /// decoded already reduced, which is most of the atlas's startup: decoding
    /// every thumbnail whole and then shrinking it cost three seconds more once
    /// the thumbnails grew to 854. Asked for all of it, the full decode is kept
    /// exactly as it was, because that is what targets are sampled from.
    public func readThumbnail(named name: String, maxPixelWidth: Int) throws -> CGImage {
        let url = url(forThumbnail: name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoIndexError.couldNotReadThumbnail(name)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0

        let image: CGImage?
        if maxPixelWidth < width {
            // A thumbnail is already the canonical 16:9 crop, landscape, so its
            // longest side is its width.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelWidth,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else { throw PhotoIndexError.couldNotReadThumbnail(name) }
        return image
    }

    public func hasThumbnail(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forThumbnail: name).path)
    }

    /// Deletes thumbnails the manifest no longer mentions. Possible only because
    /// the name is a function of the entry: everything on disk that is not in the
    /// set is, by construction, nobody's.
    ///
    /// The names are rebuilt from the last components of each URL rather than by
    /// subtracting the directory's path from the file's. That arithmetic looks
    /// obvious and is a trap: `standardizedFileURL` rewrites `/private/tmp` to
    /// `/tmp`, but only when the path exists, so the same expression gives
    /// different answers for a directory and for a file inside it. Every name
    /// then failed to match and the collector deleted the entire index.
    @discardableResult
    public func collectOrphans(keeping wanted: Set<String>) throws -> Int {
        let manager = FileManager.default
        let thumbs = directory.appendingPathComponent("thumbs", isDirectory: true)
        guard let buckets = try? manager.contentsOfDirectory(
            at: thumbs, includingPropertiesForKeys: nil
        ) else { return 0 }

        var removed = 0
        for bucket in buckets {
            guard let files = try? manager.contentsOfDirectory(
                at: bucket, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files {
                let name = "thumbs/\(bucket.lastPathComponent)/\(file.lastPathComponent)"
                if !wanted.contains(name) {
                    try? manager.removeItem(at: file)
                    removed += 1
                }
            }
        }
        return removed
    }
}
