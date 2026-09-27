import Foundation
import MosaicCore
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

    static func make(options: Options) throws -> Resolved {
        guard let folder = options.folder else {
            let count = min(options.poolSize, maximumAtlasSlices)
            return Resolved(
                source: SyntheticPhotoSource(count: count),
                description: "\(count) synthetic photographs",
                indexed: nil
            )
        }

        let store = PhotoIndexStore(directory: options.resolvedIndexDirectory)
        let folderSource = try FolderPhotoSource(root: folder)
        let root = folderSource.root.path

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
            try buildIndex(folder: folderSource, store: store, root: root, options: options)
        }

        let full = try IndexedPhotoSource(store: store, originals: folderSource)
        let pool = subset(of: full, count: options.poolSize, seed: options.seed)

        return Resolved(
            source: pool,
            description: "\(pool.entries.count) of \(full.entries.count) photographs in \(folder.lastPathComponent)",
            indexed: pool
        )
    }

    /// Builds or refreshes the index, printing progress.
    @discardableResult
    static func buildIndex(
        folder: FolderPhotoSource, store: PhotoIndexStore, root: String, options: Options
    ) throws -> IndexManifest {
        let started = Date()
        let builder = PhotoIndexBuilder(thumbnailWidth: options.thumbnailWidth, signatureSide: options.signatureSide)
        let reported = Reported()

        let manifest = try builder.build(
            from: folder, into: store, root: root,
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
            format: "  indexed %d photographs in %.1f s (%.0f/s), %d skipped",
            manifest.entries.count, elapsed, rate, manifest.skipped.count
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
