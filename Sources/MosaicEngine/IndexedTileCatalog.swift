import Foundation
import MosaicCore
import MosaicPhotos
import PhotoIndex

/// The index, read as colours.
public struct IndexedTileCatalog: TileCatalog {
    public let source: IndexedPhotoSource

    public init(source: IndexedPhotoSource) {
        self.source = source
    }

    public var photos: [PhotoID] {
        source.entries.map(\.photoID)
    }

    public func signature(for photo: PhotoID) -> TileSignature? {
        source.signature(for: photo)
    }

    public func targetGrid(for photo: PhotoID, rows: Int, detail: Int) throws -> TargetGrid {
        // Deliberately the thumbnail, at exactly the size the index stores, and
        // never the original even when one is at hand. The .saver has no
        // originals; sampling targets from them here would make the app and the
        // saver build different mosaics from the same index and the same seed,
        // and the symptom would not appear until milestone 5.
        //
        // The thumbnail is 854x480 because of this: the grid is R·k cells across
        // the crop, and the most that ever is comes to 120 · 4 = 480 rows.
        let image = try source.canonicalImage(
            for: photo, maxPixelWidth: source.manifest.thumbnailWidth
        )
        return try ImageSampling.targetGrid(of: image, rows: rows, detail: detail)
    }
}
