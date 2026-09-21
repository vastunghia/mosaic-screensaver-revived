import CoreGraphics
import Foundation
import MosaicCore
import Testing
@testable import MosaicPhotos

@Suite("Folder photo source")
struct FolderPhotoSourceTests {

    @Test("every image in the tree is found exactly once, traps and all")
    func enumeration() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }

        let source = try FolderPhotoSource(root: folder.root)
        let ids = try source.photos().map(\.id.rawValue)

        #expect(Set(ids) == HostileFolder.expectedIdentifiers)
        #expect(ids.count == Set(ids).count, "identifiers have to be unique")
        #expect(ids == ids.sorted(), "the order has to be stable across runs")
    }

    @Test("hidden files, AppleDouble sidecars and package contents stay out")
    func exclusions() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }

        let ids = Set(try FolderPhotoSource(root: folder.root).photos().map(\.id.rawValue))
        #expect(!ids.contains(".hidden.jpg"))
        #expect(!ids.contains("._sidecar.jpg"), "AppleDouble sidecars never decode")
        #expect(!ids.contains("Album.photoslibrary/inside.jpg"), "packages are opaque")
        // The type is trusted, not the bytes: a JPEG named .txt is not an image
        // as far as the file system is concerned, and we agree.
        #expect(!ids.contains("actually-an-image.txt"))
    }

    @Test("identifiers are carried whole, never parsed or escaped")
    func hostileIdentifiers() throws {
        // The original screen saver broke on %, $, # and @ in file names
        // (SPEC § 5) because an identifier went through something that
        // URL-encoded it. These have to come back byte for byte.
        let folder = try HostileFolder()
        defer { folder.remove() }

        let source = try FolderPhotoSource(root: folder.root)
        let ids = Set(try source.photos().map(\.id.rawValue))

        #expect(ids.contains("50% off/%.jpg"))
        #expect(ids.contains("$ #@.jpeg"))
        #expect(ids.contains("line\nbreak.jpg"))
        #expect(ids.contains("50% off/nested/deep.jpg"))

        // And every one of them resolves back to a file that exists.
        for descriptor in try source.photos() {
            let url = try #require(source.url(for: descriptor.id))
            #expect(FileManager.default.fileExists(atPath: url.path), descriptor.id.rawValue == "" ? "" : "\(descriptor.id.rawValue)")
        }
    }

    @Test("the same folder spelled /private/... yields the same identifiers")
    func privatePrefixedRoot() throws {
        // /tmp and /private/tmp, /var and /private/var: Foundation rewrites one
        // into the other, and only for paths that exist. Anything that subtracts
        // one path from another has to be immune to it.
        let folder = try HostileFolder()
        defer { folder.remove() }

        let plain = try FolderPhotoSource(root: folder.root)
        let prefixed = try FolderPhotoSource(root: URL(fileURLWithPath: "/private" + folder.root.path))

        let a = Set(try plain.photos().map(\.id.rawValue))
        let b = Set(try prefixed.photos().map(\.id.rawValue))
        #expect(!b.isEmpty)
        #expect(a == b)
        #expect(b.contains("50% off/%.jpg"), "identifiers must stay relative to the root")
    }

    @Test("a name spelled in NFC and in NFD is the same photograph")
    func unicodeNormalisation() throws {
        // Load-bearing and non-obvious: PhotoID compares by canonical
        // equivalence because String does, so a caller that spells a name the
        // other way still finds the photograph. If PhotoID ever compared bytes,
        // this breaks and the failure looks like a missing file.
        let folder = try HostileFolder()
        defer { folder.remove() }

        let source = try FolderPhotoSource(root: folder.root)
        let composed = PhotoID("Ünïcødé.jpg".precomposedStringWithCanonicalMapping)
        let decomposed = PhotoID("Ünïcødé.jpg".decomposedStringWithCanonicalMapping)

        #expect(composed == decomposed)
        #expect(source.url(for: composed) != nil)
        #expect(source.url(for: decomposed) != nil)
    }

    @Test("the version token changes when the file does, and not otherwise")
    func versionToken() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }

        let id = PhotoID("%.jpg")
        func token() throws -> String {
            let source = try FolderPhotoSource(root: folder.root)
            return try #require(source.photos().first { $0.id == id }?.versionToken)
        }

        let before = try token()
        #expect(try token() == before, "re-enumerating changes nothing")

        try HostileFolder.write(width: 500, height: 300, to: folder.root.appendingPathComponent("%.jpg"), type: .jpeg)
        #expect(try token() != before)
    }

    @Test("a file that will not decode fails cleanly instead of taking the run down")
    func undecodableFiles() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }

        let source = try FolderPhotoSource(root: folder.root)
        // Both are enumerated — they are images by type — and both must throw
        // rather than abort. Indexing three thousand files and dying on the one
        // corrupt one is what makes an indexer unusable.
        for name in ["empty.jpg", "actually-text.jpg"] {
            #expect(throws: PhotoSourceError.self) {
                _ = try source.canonicalImage(for: PhotoID(name), maxPixelWidth: 64)
            }
        }
        #expect(throws: PhotoSourceError.self) {
            _ = try source.canonicalImage(for: PhotoID("nothing-like-this.jpg"), maxPixelWidth: 64)
        }
    }
}
