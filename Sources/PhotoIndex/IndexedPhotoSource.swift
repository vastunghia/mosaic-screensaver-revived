import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos

/// The index, served as a `PhotoSource`.
///
/// This is not a development convenience: **it is what the .saver will do**. The
/// saver has no PhotoKit, no originals and no permission to ask for any — it
/// reads a directory of thumbnails and a manifest, and that is all. Using it now
/// means milestone 2 exercises the real contract rather than a stand-in, and it
/// happens to make every run after the first one instant.
public struct IndexedPhotoSource: PhotoSource {
    public let store: PhotoIndexStore
    public let manifest: IndexManifest

    /// Where to go when someone wants more pixels than a thumbnail has.
    ///
    /// Only the app can supply this, and only the current photograph needs it —
    /// the full-resolution texture of SPEC § 6, which is M6's business. It is
    /// here now because it is the seam, and because writing it down keeps the
    /// rule visible: originals supply **pixels**, never **choices**. Tile choice
    /// has to be a pure function of the index, or the app and the saver would
    /// build different mosaics from the same seed.
    public let originals: (any PhotoSource)?

    private let byID: [String: IndexEntry]

    public init(store: PhotoIndexStore, originals: (any PhotoSource)? = nil) throws {
        guard let manifest = try store.load() else {
            throw PhotoIndexError.missing(store.manifestURL)
        }
        self.init(store: store, manifest: manifest, originals: originals)
    }

    /// The same index narrowed to a subset of its entries — a pool rather than a
    /// library. The thumbnails stay where they are; only the list shrinks.
    public init(store: PhotoIndexStore, manifest: IndexManifest, originals: (any PhotoSource)? = nil) {
        self.store = store
        self.manifest = manifest
        self.originals = originals
        self.byID = Dictionary(manifest.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func photos() throws -> [PhotoDescriptor] {
        manifest.entries.map { PhotoDescriptor(id: $0.photoID, versionToken: $0.versionToken) }
    }

    public var entries: [IndexEntry] { manifest.entries }

    public func signature(for id: PhotoID) -> TileSignature? {
        byID[id.rawValue]?.tileSignature
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        guard let entry = byID[id.rawValue] else {
            throw PhotoSourceError.unknownPhoto(id)
        }
        if maxPixelWidth > manifest.thumbnailWidth, let originals {
            // The original's pixels, cut where the thumbnail was: the window is
            // the index's, and a close-up from anywhere else would jump in the
            // crossfade.
            guard entry.cropStart != nil else {
                return try originals.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
            }
            let upright = try originals.uprightImage(for: id, cropWidth: maxPixelWidth)
            let window = CanonicalCrop.rect(width: upright.width, height: upright.height, start: entry.cropStart)
            do {
                return try CanonicalCrop.image(upright, cropping: window, maxPixelWidth: maxPixelWidth)
            } catch {
                throw PhotoSourceError.couldNotRender(id)
            }
        }
        let image = try store.readThumbnail(named: entry.thumbnail, maxPixelWidth: maxPixelWidth)
        guard maxPixelWidth < image.width else { return image }
        // Already the canonical crop, so this only resizes.
        return try CanonicalCrop.image(image, maxPixelWidth: maxPixelWidth)
    }

    /// Only the originals have the rest of the photograph; the index keeps the
    /// crop and nothing around it.
    public func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage {
        guard let originals else { return try canonicalImage(for: id, maxPixelWidth: cropWidth) }
        return try originals.uprightImage(for: id, cropWidth: cropWidth)
    }
}
