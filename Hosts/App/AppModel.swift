import AppKit
import Foundation
import MosaicPhotoKit
import PhotoIndex

/// What the app's window shows and does: the permission, the source, the index
/// being built, the preferences, and the button that plays the effect.
///
/// Indexing runs off the main thread through the same `PhotoIndexBuilder` the
/// harness uses; its checkpoints are what make it resumable, and cancelling is
/// its `isCancelled`. The effect can start before the index is finished — the
/// original waited on "Creating photo database" until the end, which is the
/// flaw this index exists to fix.
@MainActor
final class AppModel: ObservableObject {
    /// The original would not start with fewer (SPEC § 5).
    static let minimumPhotographs = 100

    @Published var preferences: AppPreferences {
        didSet {
            preferences.save()
            if preferences.source != oldValue.source || preferences.folder != oldValue.folder
                || preferences.albumIdentifiers != oldValue.albumIdentifiers
                || preferences.allowsDownloads != oldValue.allowsDownloads
                || preferences.subsetRule != oldValue.subsetRule
                || preferences.subsetSize != oldValue.subsetSize {
                sourceChanged()
            }
        }
    }

    @Published private(set) var access = PhotoLibraryAccess.status
    @Published private(set) var albums: [PhotoLibraryAccess.Album] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var progress: IndexProgress?
    @Published private(set) var lastError: String?

    /// Photographs in the index on disk that belong to the current source.
    @Published private(set) var indexedCount = 0

    private var cancel = CancelFlag()
    private var changes: PhotoLibraryChanges?
    private var restartWhenDone = false

    init() {
        preferences = AppPreferences.load()
        refreshIndexedCount()
        if access.isGranted { accessGranted() }
    }

    var canPlay: Bool { indexedCount >= Self.minimumPhotographs && !needsAccess }

    var needsAccess: Bool {
        preferences.source == .photos && !access.isGranted
    }

    // MARK: Permission

    func requestAccess() {
        Task {
            access = await PhotoLibraryAccess.request()
            if access.isGranted { accessGranted() }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Back from System Settings: the answer may have changed behind our back.
    func refreshAccess() {
        let was = access
        access = PhotoLibraryAccess.status
        if access.isGranted, !was.isGranted { accessGranted() }
    }

    private func accessGranted() {
        loadAlbums()
        if changes == nil {
            changes = PhotoLibraryChanges { [weak self] in
                Task { @MainActor in self?.libraryChanged() }
            }
        }
        if preferences.source == .photos { startIndexing() }
    }

    private func loadAlbums() {
        Task.detached {
            let albums = PhotoLibraryAccess.albums()
            await MainActor.run { self.albums = albums }
        }
    }

    // MARK: Source

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of photographs for the mosaics."
        if panel.runModal() == .OK, let url = panel.url {
            preferences.folder = url
        }
    }

    func toggleAlbum(_ id: String) {
        if let index = preferences.albumIdentifiers.firstIndex(of: id) {
            preferences.albumIdentifiers.remove(at: index)
        } else {
            preferences.albumIdentifiers.append(id)
        }
    }

    private func sourceChanged() {
        refreshIndexedCount()
        if isIndexing {
            // The build under way is for the old source; let it stop at its
            // next batch and start over for the new one.
            restartWhenDone = true
            cancel.set()
        } else {
            startIndexing()
        }
    }

    private func libraryChanged() {
        guard preferences.source == .photos, access.isGranted else { return }
        if isIndexing { restartWhenDone = true } else { startIndexing() }
    }

    // MARK: Index

    func startIndexing() {
        guard !isIndexing, preferences.hasSource, !needsAccess else { return }
        let options = preferences.options()
        let flag = CancelFlag()
        cancel = flag
        isIndexing = true
        lastError = nil
        restartWhenDone = false

        Task.detached { [weak self] in
            do {
                guard let indexable = try PhotoSourceFactory.indexable(options: options) else { return }
                let builder = PhotoIndexBuilder(
                    thumbnailWidth: options.thumbnailWidth, signatureSide: options.signatureSide
                )
                _ = try builder.build(
                    from: indexable.source,
                    into: PhotoIndexStore(directory: options.resolvedIndexDirectory),
                    root: indexable.root,
                    progress: { progress in
                        Task { @MainActor in self?.progressed(progress) }
                    },
                    isCancelled: { flag.isSet }
                )
                await self?.finished(error: nil)
            } catch {
                await self?.finished(error: error)
            }
        }
    }

    func cancelIndexing() {
        restartWhenDone = false
        cancel.set()
    }

    private func progressed(_ progress: IndexProgress) {
        self.progress = progress
        indexedCount = progress.completed - progress.skipped - progress.unavailable
    }

    private func finished(error: Error?) {
        isIndexing = false
        if let error { lastError = "\(error)" }
        refreshIndexedCount()
        if restartWhenDone { startIndexing() }
    }

    /// What is on disk, for the current source. Also right while a build runs,
    /// since every checkpoint is a whole manifest.
    private func refreshIndexedCount() {
        let options = preferences.options()
        let store = PhotoIndexStore(directory: options.resolvedIndexDirectory)
        let root: String? = switch preferences.source {
        case .photos: PhotoKitPhotoSource.indexRoot
        case .folder: preferences.folder.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        }
        guard let root,
              let manifest = try? store.load(),
              manifest.matches(root: root, thumbnailWidth: options.thumbnailWidth,
                               signatureSide: options.signatureSide)
        else {
            indexedCount = 0
            return
        }
        indexedCount = manifest.entries.count
    }
}

extension PhotoLibraryAccess.Status {
    var isGranted: Bool { self == .authorized || self == .limited }
}

/// Set from the main thread, read from the builder's.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}
