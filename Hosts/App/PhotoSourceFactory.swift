import Foundation
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex

/// Where the photographs come from, decided in exactly one place.
///
/// The window and both exporters go through here so they cannot drift apart and
/// render different pools — which would make two exports incomparable without
/// anything looking wrong in either.
enum PhotoSourceFactory {
    struct Resolved {
        let source: any PhotoSource
        let description: String
        /// Present only when there is a real index behind the source, which is
        /// what the solver needs to see colours.
        let indexed: IndexedPhotoSource?
    }

    /// Where close-ups come from, for `--close-ups`.
    static func closeUpSource(_ mode: Options.CloseUps, photos: Resolved) -> (any PhotoSource)? {
        switch mode {
        case .off:
            return nil
        case .originals:
            return photos.source
        case .thumbnails:
            // The same index with no originals behind it: what the .saver
            // reads, and all it reads.
            guard let indexed = photos.indexed else { return photos.source }
            return IndexedPhotoSource(store: indexed.store, manifest: indexed.manifest)
        }
    }

    /// Metal's 2D texture arrays top out here, and the atlas is one array with a
    /// slice per photograph. Past it `makeTexture` returns nil and the only
    /// symptom is a failure to allocate, with nothing to say why.
    static let maximumAtlasSlices = 2048

    /// A source that an index can be built from: what it is, the `root` its
    /// manifest records, and a name to print.
    struct Indexable {
        let source: any PhotoSource
        let root: String
        let name: String
    }

    /// The folder or the library the options point at, or nil for synthetic
    /// photographs. For the library this is where the permission is asked.
    static func indexable(options: Options) throws -> Indexable? {
        if options.photosLibrary {
            try authorizePhotos()
            let scope = options.albumIdentifiers.isEmpty
                ? try photoKitScope(albums: options.albums)
                : .albums(options.albumIdentifiers)
            let library = PhotoKitPhotoSource(scope: scope, allowsNetworkAccess: options.allowsDownloads)
            return Indexable(
                source: SubsetPhotoSource(
                    library, rule: options.subsetRule, count: options.subsetSize, seed: options.subsetSeed
                ),
                root: PhotoKitPhotoSource.indexRoot,
                name: options.albums.isEmpty
                    ? (options.albumIdentifiers.isEmpty ? "the Photos library" : "the chosen albums")
                    : options.albums.joined(separator: ", ")
            )
        }
        guard let folder = options.folder else { return nil }
        let source = try FolderPhotoSource(root: folder)
        return Indexable(source: source, root: source.root.path, name: folder.lastPathComponent)
    }

    static func make(options: Options) throws -> Resolved {
        guard let indexable = try indexable(options: options) else {
            let count = min(options.poolSize, maximumAtlasSlices)
            return Resolved(
                source: SyntheticPhotoSource(count: count),
                description: "\(count) synthetic photographs",
                indexed: nil
            )
        }

        let store = PhotoIndexStore(directory: options.resolvedIndexDirectory)
        let root = indexable.root

        // An index built for another folder cannot be reused: identifiers are
        // paths relative to a root, so two folders of the same shape would
        // otherwise share them and serve each other's photographs.
        let usable = try store.load()?.matches(
            root: root,
            thumbnailWidth: options.thumbnailWidth,
            signatureSide: options.signatureSide
        ) ?? false

        if !usable {
            print("no usable index for \(root) — building one")
            try buildIndex(source: indexable.source, store: store, root: root, options: options)
        } else if options.photosLibrary {
            // The root says "the library" whatever the albums and the subset
            // rule are, so a usable index may still be of another subset. An
            // incremental pass settles it, and reads nothing when nothing
            // changed. A folder's root pins its contents, and exports from it
            // stay exactly as they were.
            try buildIndex(source: indexable.source, store: store, root: root, options: options)
        }

        let full = try IndexedPhotoSource(store: store, originals: indexable.source)
        let pool = subset(of: full, count: options.poolSize, seed: options.seed)

        return Resolved(
            source: pool,
            description: "\(pool.entries.count) of \(full.entries.count) photographs in \(indexable.name)",
            indexed: pool
        )
    }

    /// Asks for the library if nobody has yet, and refuses to go on without it.
    /// Blocking is fine here: the harness has nothing to show until it knows.
    static func authorizePhotos() throws {
        var status = PhotoLibraryAccess.status
        if status == .notDetermined {
            let answer = Answer()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                answer.status = await PhotoLibraryAccess.request()
                done.signal()
            }
            done.wait()
            status = answer.status ?? .denied
        }
        guard status == .authorized || status == .limited else {
            throw HarnessError.photosNotAuthorized(status)
        }
        if status == .limited {
            print("  limited access: only the photographs picked in System Settings are visible")
        }
    }

    private static func photoKitScope(albums titles: [String]) throws -> PhotoKitPhotoSource.Scope {
        guard !titles.isEmpty else { return .library }
        let albums = PhotoLibraryAccess.albums()
        let chosen = albums.filter { titles.contains($0.title) }
        let missing = titles.filter { title in !chosen.contains { $0.title == title } }
        guard missing.isEmpty else {
            throw HarnessError.unknownAlbums(missing, known: albums.map(\.title))
        }
        return .albums(chosen.map(\.id))
    }

    /// Builds or refreshes the index, printing progress.
    @discardableResult
    static func buildIndex(
        source: any PhotoSource, store: PhotoIndexStore, root: String, options: Options
    ) throws -> IndexManifest {
        let started = Date()
        let builder = PhotoIndexBuilder(thumbnailWidth: options.thumbnailWidth, signatureSide: options.signatureSide)
        let reported = Reported()

        let manifest = try builder.build(
            from: source, into: store, root: root,
            progress: { progress in
                guard progress.total > 0 else { return }
                let percent = progress.completed * 100 / progress.total
                if reported.shouldReport(percent, of: progress) {
                    print("  indexing \(progress.completed)/\(progress.total) (\(percent)%)")
                }
            }
        )

        let elapsed = Date().timeIntervalSince(started)
        let rate = elapsed > 0 ? Double(manifest.entries.count) / elapsed : 0
        print(String(
            format: "  indexed %d photographs in %.1f s (%.0f/s), %d skipped, %d not on this Mac",
            manifest.entries.count, elapsed, rate, manifest.skipped.count, manifest.unavailable.count
        ))
        print("  at \(store.directory.path)")
        return manifest
    }

    /// A deterministic subset, because the atlas has a ceiling and a library does
    /// not. Seeded rather than "the first N": the entries are sorted by
    /// identifier, so taking a prefix would take one corner of the folder.
    ///
    /// It follows the session's seed, so a library bigger than the atlas is
    /// drawn from afresh at every launch: with a fixed subset, a 54,000-photo
    /// library would show the same 2048 forever.
    private static func subset(of source: IndexedPhotoSource, count: Int, seed: UInt64) -> IndexedPhotoSource {
        let limit = min(count, maximumAtlasSlices)
        guard source.entries.count > limit else { return source }

        var rng = SplitMix64(seed: seed ^ 0x5EED_0F00)
        let chosen = Array(rng.shuffled(source.entries).prefix(limit))
        var manifest = source.manifest
        manifest.entries = chosen.sorted { $0.id < $1.id }

        if count > maximumAtlasSlices {
            print("  pool capped at \(maximumAtlasSlices): one texture array holds no more slices")
        }
        return IndexedPhotoSource(
            store: source.store, manifest: manifest, originals: source.originals
        )
    }
}


/// The permission, carried out of the task that asked for it.
private final class Answer: @unchecked Sendable {
    var status: PhotoLibraryAccess.Status?
}

/// Progress arrives from whichever thread finished a batch, so the last figure
/// printed needs a lock rather than a captured var.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func shouldReport(_ percent: Int, of progress: IndexProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard percent >= last + 5 || progress.completed == progress.total else { return false }
        last = percent
        return true
    }
}
