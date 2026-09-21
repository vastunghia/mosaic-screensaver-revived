import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Testing
@testable import PhotoIndex

/// A source that counts how often it is asked to decode, which is how
/// incrementality is asserted: not "it was quick" but "it read exactly three".
private final class CountingSource: PhotoSource, @unchecked Sendable {
    let inner: FolderPhotoSource
    private let lock = NSLock()
    private var decodes = 0

    init(root: URL) throws {
        inner = try FolderPhotoSource(root: root)
    }

    var decodeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return decodes
    }

    func resetCount() {
        lock.lock(); defer { lock.unlock() }
        decodes = 0
    }

    func photos() throws -> [PhotoDescriptor] { try inner.photos() }

    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        lock.lock(); decodes += 1; lock.unlock()
        return try inner.canonicalImage(for: id, maxPixelWidth: maxPixelWidth)
    }
}

@Suite("Photo index")
struct PhotoIndexTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-index-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func builder() -> PhotoIndexBuilder {
        // Small, so the tests are quick; the shape is what is being tested.
        PhotoIndexBuilder(thumbnailWidth: 128, signatureSide: 4, checkpointEvery: 4)
    }

    @Test("indexing a folder records every readable photograph and no more")
    func firstBuild() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let source = try FolderPhotoSource(root: folder.root)
        let store = PhotoIndexStore(directory: index)
        let manifest = try builder().build(from: source, into: store, root: folder.root.path)

        let readable = Set(HostileFolder.images + ["tall.jpg", "rotated.jpg"])
        #expect(Set(manifest.entries.map(\.id)) == readable)
        #expect(Set(manifest.skipped) == ["empty.jpg", "actually-text.jpg"])

        for entry in manifest.entries {
            #expect(store.hasThumbnail(named: entry.thumbnail), entry.id == "" ? "" : "\(entry.id)")
            let signature = try #require(entry.tileSignature)
            #expect(signature.side == 4)
        }
    }

    @Test("a second build reads nothing, and adding three photographs reads three")
    func incrementality() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        let first = try CountingSource(root: folder.root)
        let initial = try builder().build(from: first, into: store, root: folder.root.path)
        #expect(first.decodeCount > 0)

        let second = try CountingSource(root: folder.root)
        _ = try builder().build(from: second, into: store, root: folder.root.path)
        #expect(second.decodeCount == 0, "nothing changed, so nothing may be read again")

        for name in ["added-1.jpg", "added-2.jpg", "added-3.jpg"] {
            try HostileFolder.write(
                width: 200, height: 120, to: folder.root.appendingPathComponent(name), type: .jpeg
            )
        }
        let third = try CountingSource(root: folder.root)
        let grown = try builder().build(from: third, into: store, root: folder.root.path)
        #expect(third.decodeCount == 3, "read \(third.decodeCount) instead of the three new ones")
        #expect(grown.entries.count == initial.entries.count + 3)
    }

    @Test("changing one photograph reindexes one photograph and collects its old thumbnail")
    func invalidation() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        _ = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )
        let before = try #require(try store.load()?.entries.first { $0.id == "%.jpg" })

        try HostileFolder.write(
            width: 400, height: 260, to: folder.root.appendingPathComponent("%.jpg"), type: .jpeg
        )
        let source = try CountingSource(root: folder.root)
        _ = try builder().build(from: source, into: store, root: folder.root.path)

        #expect(source.decodeCount == 1, "read \(source.decodeCount)")
        let after = try #require(try store.load()?.entries.first { $0.id == "%.jpg" })
        #expect(after.thumbnail != before.thumbnail, "a new version has to get a new name")
        #expect(!store.hasThumbnail(named: before.thumbnail), "the old thumbnail is an orphan")
        #expect(store.hasThumbnail(named: after.thumbnail))
    }

    @Test("removing photographs removes their entries and their pixels")
    func deletion() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        let before = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )
        let doomed = try #require(before.entries.first { $0.id == "UPPER.JPG" })

        try FileManager.default.removeItem(at: folder.root.appendingPathComponent("UPPER.JPG"))
        let after = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )

        #expect(after.entries.count == before.entries.count - 1)
        #expect(!after.entries.contains { $0.id == "UPPER.JPG" })
        #expect(!store.hasThumbnail(named: doomed.thumbnail))
    }

    @Test("two builds over the same folder produce a byte-identical manifest")
    func idempotence() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        _ = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )
        let first = try #require(FileManager.default.contents(atPath: store.manifestURL.path))

        _ = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )
        let second = try #require(FileManager.default.contents(atPath: store.manifestURL.path))

        #expect(first == second, "sorted entries make this free, and it is worth having")
    }

    @Test("an index built for one folder refuses to serve another")
    func rootBinding() throws {
        // Identifiers are relative paths, so two folders with the same internal
        // shape give the same identifiers. Nothing else would stop one index
        // from quietly serving the wrong photographs.
        let first = try HostileFolder()
        defer { first.remove() }
        let second = try HostileFolder()
        defer { second.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        _ = try builder().build(
            from: try FolderPhotoSource(root: first.root), into: store, root: first.root.path
        )
        let stored = try #require(try store.load())
        #expect(!stored.matches(root: second.root.path, thumbnailWidth: 128, signatureSide: 4))

        // Building against the other folder starts over rather than mixing.
        let rebuilt = try builder().build(
            from: try FolderPhotoSource(root: second.root), into: store, root: second.root.path
        )
        #expect(rebuilt.root == second.root.path)
    }

    @Test("a different thumbnail size or signature side rebuilds instead of mixing")
    func formatChangesRebuild() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        _ = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )

        let source = try CountingSource(root: folder.root)
        let wider = PhotoIndexBuilder(thumbnailWidth: 256, signatureSide: 4, checkpointEvery: 4)
        let rebuilt = try wider.build(from: source, into: store, root: folder.root.path)

        #expect(source.decodeCount > 0, "a size change cannot reuse the old pixels")
        #expect(rebuilt.thumbnailWidth == 256)
        #expect(rebuilt.entries.allSatisfy { $0.pixelWidth <= 256 })
    }

    @Test("an index under /private survives a rebuild with its thumbnails intact")
    func privatePrefixedPaths() throws {
        // The regression that ate an entire index. `standardizedFileURL` rewrites
        // /private/tmp to /tmp, but only for paths that exist — so subtracting a
        // directory's components from a file's inside it drops one component too
        // many, every thumbnail name comes out wrong, and the orphan collector
        // decides the whole index is rubbish. It only shows on volumes where the
        // two spellings differ, which is why the ordinary tests missed it.
        let folder = try HostileFolder()
        defer { folder.remove() }

        let plain = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: plain) }
        let prefixed = URL(fileURLWithPath: "/private" + plain.path)

        let store = PhotoIndexStore(directory: prefixed)
        let source = try FolderPhotoSource(root: URL(fileURLWithPath: "/private" + folder.root.path))
        #expect(try !source.photos().isEmpty, "the /private spelling has to enumerate too")

        let first = try builder().build(from: source, into: store, root: source.root.path)
        #expect(!first.entries.isEmpty)
        for entry in first.entries {
            #expect(store.hasThumbnail(named: entry.thumbnail), "lost \(entry.thumbnail)")
        }

        // And again, which is when the collector runs against a full index.
        let again = try builder().build(from: source, into: store, root: source.root.path)
        for entry in again.entries {
            #expect(store.hasThumbnail(named: entry.thumbnail), "collected \(entry.thumbnail)")
        }
    }

    @Test("a damaged or foreign manifest reads as no index, never as a crash")
    func damagedManifest() throws {
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        #expect(try store.load() == nil, "no file at all")

        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: store.manifestURL)
        #expect(try store.load() == nil, "half a file")

        let fromTheFuture = IndexManifest(
            formatVersion: 999, root: "/nowhere",
            thumbnailWidth: 640, thumbnailHeight: 360, signatureSide: 4
        )
        try JSONEncoder().encode(fromTheFuture).write(to: store.manifestURL)
        #expect(try store.load() == nil, "another format version")
    }

    @Test("the manifest is replaced atomically, so a reader never sees half of one")
    func atomicReplacement() throws {
        // There is no lock between the app and the saver, and the app may rewrite
        // the index while the saver is reading it. This hammers both sides at
        // once: every read has to yield a whole manifest, old or new.
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)

        func manifest(count: Int) -> IndexManifest {
            IndexManifest(
                root: "/root", thumbnailWidth: 640, thumbnailHeight: 360, signatureSide: 4,
                entries: (0..<count).map {
                    IndexEntry(
                        id: "photo-\($0).jpg", versionToken: "v1",
                        thumbnail: "thumbs/aa/\($0).jpg",
                        signature: TileSignature(mean: .white),
                        pixelWidth: 640, pixelHeight: 360
                    )
                }
            )
        }

        try store.save(manifest(count: 400))
        let failures = Failures()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<40 {
                if worker == 0 {
                    try? store.save(manifest(count: round.isMultiple(of: 2) ? 400 : 900))
                } else {
                    do {
                        let loaded = try store.load()
                        if loaded == nil { failures.record() }
                    } catch {
                        failures.record()
                    }
                }
            }
        }

        #expect(failures.count == 0, "\(failures.count) reads saw a torn manifest")
    }

    @Test("no thumbnail path ever contains a piece of an identifier")
    func identifiersNeverBecomePaths() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let store = PhotoIndexStore(directory: index)
        let manifest = try builder().build(
            from: try FolderPhotoSource(root: folder.root), into: store, root: folder.root.path
        )

        for entry in manifest.entries {
            let stem = (entry.id as NSString).deletingPathExtension
            for piece in stem.split(separator: "/") where piece.count >= 2 {
                #expect(
                    !entry.thumbnail.contains(piece),
                    "\(entry.thumbnail) carries a piece of \(entry.id)"
                )
            }
        }
    }

    @Test("the colour survives the round trip through JPEG and JSON")
    func colourFidelity() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }

        let source = try FolderPhotoSource(root: folder.root)
        let store = PhotoIndexStore(directory: index)
        _ = try builder().build(from: source, into: store, root: folder.root.path)

        let indexed = try IndexedPhotoSource(store: store)
        for entry in indexed.entries.prefix(6) {
            let stored = try #require(entry.tileSignature)
            let image = try indexed.canonicalImage(for: entry.photoID, maxPixelWidth: 128)
            let recomputed = try ImageSampling.signature(of: image, side: 4)
            for (a, b) in zip(stored.labCells, recomputed.labCells) {
                #expect(a.deltaE(to: b) < 6, "\(entry.id) drifted by \(a.deltaE(to: b))")
            }
        }
    }

    @Test("a cancelled build leaves a valid index and resumes without redoing the work")
    func cancellationAndResume() throws {
        let folder = try HostileFolder()
        defer { folder.remove() }

        // What a build from scratch costs, to measure the other two against.
        let whole = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: whole) }
        let reference = try CountingSource(root: folder.root)
        let complete = try builder().build(
            from: reference, into: PhotoIndexStore(directory: whole), root: folder.root.path
        )
        let wholeCost = reference.decodeCount

        // The same build, stopped after its first checkpoint.
        let index = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: index) }
        let store = PhotoIndexStore(directory: index)
        let stopper = Failures()
        let interrupted = try CountingSource(root: folder.root)
        _ = try builder().build(
            from: interrupted, into: store, root: folder.root.path,
            progress: nil,
            isCancelled: {
                defer { stopper.record() }
                return stopper.count > 0
            }
        )

        let partial = try store.load()
        let saved = try #require(partial)
        #expect(!saved.entries.isEmpty, "a checkpoint has to have been written")
        #expect(interrupted.decodeCount < wholeCost, "it was supposed to stop early")

        // Resuming picks up exactly where it left off: no work done twice, and
        // none skipped.
        let resumed = try CountingSource(root: folder.root)
        let finished = try builder().build(from: resumed, into: store, root: folder.root.path)

        #expect(resumed.decodeCount == wholeCost - interrupted.decodeCount,
                "resumed \(resumed.decodeCount), expected \(wholeCost - interrupted.decodeCount)")
        #expect(Set(finished.entries.map(\.id)) == Set(complete.entries.map(\.id)))
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }
}
