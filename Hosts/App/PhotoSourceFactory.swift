import Foundation
import MosaicCore
import MosaicEngine
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
    static func closeUpSource(_ mode: Options.CloseUps, photos: Resolved, shelf: CloseUpShelf) -> (any PhotoSource)? {
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
        case .stored:
            // What the .saver reads now: the shelf, and the thumbnails where
            // it has a gap.
            guard let indexed = photos.indexed else { return photos.source }
            return ShelvedPhotoSource(
                index: IndexedPhotoSource(store: indexed.store, manifest: indexed.manifest), shelf: shelf
            )
        }
    }

    static let maximumAtlasSlices = MosaicEngine.maximumPoolSize

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
            let scope = options.collectionIdentifiers.isEmpty
                ? try photoKitScope(albums: options.albums)
                : .collections(options.collectionIdentifiers)
            let library = PhotoKitPhotoSource(scope: scope, allowsNetworkAccess: options.allowsDownloads)
            return Indexable(
                source: SubsetPhotoSource(
                    library, rule: options.subsetRule, count: options.subsetSize, seed: options.subsetSeed
                ),
                root: PhotoKitPhotoSource.indexRoot,
                name: options.albums.isEmpty
                    ? (options.collectionIdentifiers.isEmpty ? "the Photos library" : "the chosen albums and folders")
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
            signatureSide: options.signatureSide,
            cropRule: options.cropRule
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
        if options.poolSize > maximumAtlasSlices, full.entries.count > maximumAtlasSlices {
            print("  pool capped at \(maximumAtlasSlices): one texture array holds no more slices")
        }
        let pool = full.pool(size: min(options.poolSize, maximumAtlasSlices), seed: options.seed)

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
        return .collections(chosen.map(\.id))
    }

    /// Builds or refreshes the index, printing progress.
    @discardableResult
    static func buildIndex(
        source: any PhotoSource, store: PhotoIndexStore, root: String, options: Options
    ) throws -> IndexManifest {
        let started = Date()
        let builder = PhotoIndexBuilder(
            thumbnailWidth: options.thumbnailWidth, signatureSide: options.signatureSide, cropRule: options.cropRule
        )
        let reported = Reported()

        let manifest = try builder.build(
            from: source, into: store, root: root, availability: options.availability,
            preferring: options.closeUpPreference,
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
        let tiles = manifest.entries.filter { !$0.canFillScreen }.count
        if tiles > 0 || !manifest.belowFullScreen.isEmpty {
            print("  \(manifest.entries.count - tiles) fill the screen, \(tiles) tiles only; "
                  + "\(manifest.belowFullScreen.count) known below full screen")
        }
        print("  at \(store.directory.path)")
        return manifest
    }
}


extension PhotoSourceFactory {
    /// Makes the close-ups the .saver reads, for the whole index the source
    /// was just indexed into, printing progress.
    @discardableResult
    static func stockCloseUps(
        source: any PhotoSource, store: PhotoIndexStore, shelf: CloseUpShelf,
        fetching: CloseUpShelf.Fetching? = nil, isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> CloseUpShelf.StockReport {
        let started = Date()
        let index = try IndexedPhotoSource(store: store, originals: source)
        let reported = Reported()
        let report = try shelf.stock(
            from: index,
            fetching: fetching,
            progress: { report in
                // While fetching, the count of close-ups does not move.
                if report.toFetch > 0 {
                    print("  fetched \(report.fetched), asked \(report.asked) of \(report.toFetch)")
                    return
                }
                let done = report.kept + report.made + report.failed + report.unavailable
                guard report.total > 0 else { return }
                let progress = IndexProgress(completed: done, reused: report.kept, skipped: 0, total: report.total)
                if reported.shouldReport(done * 100 / report.total, of: progress) {
                    print("  close-ups \(done)/\(report.total)")
                }
            },
            isCancelled: isCancelled
        )
        let elapsed = Date().timeIntervalSince(started)
        print(String(
            format: "  close-ups at %d px: %d made in %.1f s (%.1f/s), %d kept, %d failed, %d not on this Mac, %d removed, %d tiles only",
            shelf.width, report.made, elapsed, elapsed > 0 ? Double(report.made) / elapsed : 0,
            report.kept, report.failed, report.unavailable, report.removed, report.tilesOnly
        ))
        if fetching != nil {
            print("  of those made, \(report.fetched) fetched from iCloud; \(report.deferred) held back by the caps, \(report.timedOut) given up as too slow, \(report.resting) resting after too many\(report.stalled ? "; \(report.leftForLater) left for later as iCloud stalled" : "")")
        }
        print("  at \(shelf.directory.path)")
        return report
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
