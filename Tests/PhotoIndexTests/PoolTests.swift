import Foundation
import MosaicCore
import PhotoIndex
import Testing

/// The pool is what the app and the .saver both draw from an index for a
/// session, so the same seed has to give both the same photographs.
@Suite("Pool")
struct PoolTests {
    private func index(count: Int) -> IndexedPhotoSource {
        let entries = (0..<count).map { number in
            IndexEntry(
                id: String(format: "photo-%04d", number), versionToken: "1", thumbnail: "thumbs/none.jpg",
                signature: TileSignature(side: 1, cells: [LinearRGB(r: 0, g: 0, b: 0)]),
                pixelWidth: 16, pixelHeight: 9
            )
        }
        let manifest = IndexManifest(
            root: "/pool", thumbnailWidth: 16, thumbnailHeight: 9, signatureSide: 1, entries: entries
        )
        return IndexedPhotoSource(
            store: PhotoIndexStore(directory: FileManager.default.temporaryDirectory), manifest: manifest
        )
    }

    @Test("a pool is a seeded subset, sorted like the index")
    func seededSubset() {
        let full = index(count: 300)
        let pool = full.pool(size: 100, seed: 7)
        let ids = pool.entries.map(\.id)

        #expect(ids.count == 100)
        #expect(ids == ids.sorted())
        #expect(Set(ids).isSubset(of: Set(full.entries.map(\.id))))
        #expect(ids != Array(full.entries.map(\.id).prefix(100)), "not a corner of the index")
        #expect(full.pool(size: 100, seed: 7).entries.map(\.id) == ids, "the same seed, the same pool")
        #expect(full.pool(size: 100, seed: 8).entries.map(\.id) != ids, "another seed, another pool")
    }

    @Test("an index no bigger than the pool is the pool")
    func smallIndex() {
        let full = index(count: 50)
        #expect(full.pool(size: 50, seed: 1).entries.map(\.id) == full.entries.map(\.id))
        #expect(full.pool(size: 2048, seed: 1).entries.map(\.id) == full.entries.map(\.id))
    }
}
