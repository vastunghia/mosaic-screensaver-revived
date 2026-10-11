import AppKit
import Foundation
import MosaicPhotoKit
import PhotoIndex
import os
import ServiceManagement
import SharedStore
import UserNotifications

/// What the app's window shows and does: the permission, the source, the index
/// being built, the preferences, and the button that plays the effect.
///
/// Indexing runs off the main thread through the same `PhotoIndexBuilder` the
/// harness uses; its checkpoints are what make it resumable, and cancelling is
/// its `isCancelled`. The effect can start before the index is finished — the
/// original waited on "Creating photo database" until the end, which is the
/// flaw this index exists to fix.
///
/// The model also runs with nobody in front of it: launched at login, or by
/// the .saver through `mosaic://update`, the app has no window, and then it
/// never asks for anything — a Photos prompt behind the screen saver would go
/// unseen (spike 4). It notes that it was wanted and asks when a window opens.
@MainActor
final class AppModel: ObservableObject {
    /// The original would not start with fewer (SPEC § 5).
    static let minimumPhotographs = 100

    @Published var preferences: AppPreferences {
        didSet {
            preferences.save()
            if preferences.shared != oldValue.shared { shareSettings() }
            if preferences.source != oldValue.source || preferences.folder != oldValue.folder
                || preferences.collectionIdentifiers != oldValue.collectionIdentifiers
                || preferences.allowsDownloads != oldValue.allowsDownloads
                || preferences.subsetRule != oldValue.subsetRule
                || preferences.subsetSize != oldValue.subsetSize {
                sourceChanged()
            }
        }
    }

    @Published private(set) var access = PhotoLibraryAccess.status
    @Published private(set) var albums = AlbumTree(roots: [])
    @Published private(set) var isIndexing = false
    @Published private(set) var progress: IndexProgress?
    @Published private(set) var problem: Problem?
    @Published private(set) var loginItem = SMAppService.mainApp.status
    @Published private(set) var saver = SaverInstaller.State.unavailable
    /// The last answer known, so that the window opens on the right steps
    /// before the system has been asked again.
    @Published private(set) var notifications = UNAuthorizationStatus(
        rawValue: UserDefaults.standard.integer(forKey: AppModel.notificationsKey)) ?? .notDetermined

    /// Why the .saver last called while there was no Photos grant, if it has
    /// not been dealt with yet.
    @Published private(set) var pendingSaverRequest: String?

    /// Photographs in the index on disk that belong to the current source.
    @Published private(set) var indexedCount = 0

    private var cancel = CancelFlag()
    private var changes: PhotoLibraryChanges?
    private var restartWhenDone = false

    /// Whether a window is, or has been, open: someone may be looking.
    private var foreground: Bool
    private var albumsLoaded = false

    /// Indexing blocks — `concurrentPerform`, synchronous PhotoKit, a first
    /// fetch that waits minutes at login — so it runs on a queue of its own,
    /// not on the cooperative pool, whose few threads it would hold.
    private static let indexQueue = DispatchQueue(label: "mosaic.index")

    init(foreground: Bool) {
        self.foreground = foreground
        preferences = AppPreferences.load()
        pendingSaverRequest = UserDefaults.standard.string(forKey: Self.pendingKey)
        refreshIndexedCount()
        // Also at launch: the file may predate these settings, or be missing.
        if SharedSettings.read() != preferences.shared { shareSettings() }
        if access.isGranted { accessGranted() }
    }

    /// `R` and `T` for the .saver, next to the index.
    private func shareSettings() {
        do {
            try preferences.shared.write()
        } catch {
            Self.log.error("the screen saver's settings could not be written: \(error, privacy: .public)")
        }
    }

    var canPlay: Bool { hasIndex && !needsAccess }

    // MARK: The steps of the window

    /// Running from where the download was unpacked (`AppLocation`).
    let isTranslocated = AppLocation.isTranslocated

    /// Step: there are photographs to read.
    var hasPhotographs: Bool {
        preferences.hasSource && !needsAccess
    }

    /// Step: enough of them indexed for the effect, and for the saver.
    var hasIndex: Bool { indexedCount >= Self.minimumPhotographs }

    /// Every step done: the window shows a line of status instead of them.
    /// Not while something went wrong, which belongs to a step.
    var isSetUp: Bool {
        !isTranslocated && hasPhotographs && hasIndex && saver == .installed && hasAnsweredNotifications
            && problem == nil
    }

    /// Step: the user has said whether Mosaic may announce new versions. A
    /// no is an answer too, and the step is done with it.
    var hasAnsweredNotifications: Bool { notifications != .notDetermined }

    /// Which photographs of the library, in one line, however many albums
    /// there are: the list itself lives in a sheet. Laid out inline, a Form
    /// built one view per album at once, and on a library with many albums
    /// that held the main thread — and the effect drawn on it — for over ten
    /// seconds.
    var albumSummary: String {
        let chosen = preferences.collectionIdentifiers
        if chosen.isEmpty { return "All photographs" }
        let titles = albums.titles(of: chosen)
        if titles.isEmpty { return chosen.count == 1 ? "1 album" : "\(chosen.count) albums" }
        return titles.joined(separator: ", ")
    }

    func moveToApplications() {
        cancelIndexing()
        Task {
            do {
                try await AppLocation.moveToApplications()
                MosaicApplication.quitWithoutAsking()
            } catch {
                report(.location, """
                    Mosaic could not be moved to Applications (\(error.localizedDescription)). \
                    Drag it there in the Finder, then open it again.
                    """)
            }
        }
    }

    var needsAccess: Bool {
        preferences.source == .photos && !access.isGranted
    }

    // MARK: Problems

    private func report(_ place: Problem.Place, _ message: String) {
        problem = Problem(place: place, message: message)
    }

    private func clearProblem(at place: Problem.Place) {
        if problem?.place == place { problem = nil }
    }

    // MARK: Who is in front

    /// A window has opened: from now on there is someone to ask.
    func windowOpened() {
        foreground = true
        refreshAccess()
        refreshLoginItem()
        refreshSaver()
        refreshNotifications()
        if access.isGranted {
            loadAlbums()
        } else if pendingSaverRequest != nil, access == .notDetermined, preferences.source == .photos {
            // The screen saver wanted photographs while nobody could answer.
            requestAccess()
        }
    }

    /// The window has closed and the app stays, as a login item: nobody to
    /// ask any more, and the next pass yields to everything else again.
    func windowClosed() {
        foreground = false
    }

    /// `mosaic://update`, or a launch at login: bring the index up to date if
    /// it can be done without asking anyone.
    func updateRequested(reason: String) {
        Self.log.notice("update requested: \(reason, privacy: .public)")
        if needsAccess, !foreground {
            Self.log.notice("no Photos grant, and nobody to ask: noted for the next time the window opens")
            pendingSaverRequest = reason
            UserDefaults.standard.set(reason, forKey: Self.pendingKey)
        }
        // A pass under way is as fresh as a new one would be: unlike a change
        // in the library, nothing has happened since it started.
        startIndexing()
        if !isIndexing { quitIfIdle() }
    }

    /// Launched without a window and with nothing left to do: only a login
    /// item stays, to keep watching the library. Without this, a call the app
    /// could not act on — no grant, no folder — left it running unseen.
    private func quitIfIdle() {
        guard !foreground else { return }
        refreshLoginItem()
        guard !opensAtLogin else { return }
        Self.log.notice("nothing left to do without a window: quitting")
        MosaicApplication.quitWithoutAsking()
    }

    private static let pendingKey = "pendingSaverRequest"

    // MARK: Screen saver

    /// Read from disk every time: the user can remove it in System Settings.
    func refreshSaver() {
        saver = SaverInstaller.state
    }

    /// Installs or updates the saver, then shows where it is chosen. The
    /// first time, Mosaic also starts opening at login, which is what keeps
    /// the screen saver's photographs current; Settings turns it off.
    func installSaver() {
        let first = saver == .notInstalled
        do {
            try SaverInstaller.install { SaverInstaller.openSettings() }
            clearProblem(at: .screenSaver)
        } catch {
            report(.screenSaver, "The screen saver could not be installed: \(error.localizedDescription)")
        }
        refreshSaver()
        refreshLoginItem()
        if first, saver == .installed, !isTranslocated, loginItem == .notRegistered {
            setOpensAtLogin(true, reportingAt: .screenSaver)
        }
    }

    func openScreenSaverSettings() {
        SaverInstaller.openSettings()
    }

    /// The first launch after an update (`Updater`): the saver this app
    /// carries is new as well, and the installed one is brought in line
    /// without a click — if there is one; a user who never installed it is
    /// not given one.
    func finishUpdate() {
        guard Updater.takeJustUpdated() else { return }
        refreshSaver()
        guard saver == .different else { return }
        do {
            try SaverInstaller.install {}
            clearProblem(at: .screenSaver)
        } catch {
            report(.screenSaver, "The screen saver could not be updated: \(error.localizedDescription)")
        }
        refreshSaver()
    }

    // MARK: Login item

    /// Read from the system every time: the user can change it in System
    /// Settings behind the app's back.
    func refreshLoginItem() {
        loginItem = SMAppService.mainApp.status
    }

    func setOpensAtLogin(_ on: Bool, reportingAt place: Problem.Place = .settings) {
        // Turned off by hand is an answer: the window stops asking. Turned on
        // again, it may ask once more if the system later loses it.
        UserDefaults.standard.set(!on, forKey: Self.declinedLoginKey)
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            clearProblem(at: place)
        } catch {
            report(place, "Mosaic could not \(on ? "be added to" : "be removed from") the login items: \(error.localizedDescription)")
        }
        refreshLoginItem()
        Self.log.notice("login item \(on ? "registered" : "unregistered", privacy: .public), status \(self.loginItem.rawValue, privacy: .public)")
    }

    var opensAtLogin: Bool {
        loginItem == .enabled || loginItem == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether to invite the user, as a window opens, to let Mosaic open at
    /// login: without it the index is brought up to date only while the app
    /// happens to run, and the screen saver falls behind the library unseen.
    /// Installing the saver turns it on, but a saver installed some other way
    /// (`build.sh --install`), or a login item removed in System Settings,
    /// leaves it off with nobody saying so. Not once the user has said no:
    /// "Don't ask again" in the invitation, or the switch in Settings.
    var invitesToOpenAtLogin: Bool {
        !isTranslocated && saver == .installed && !opensAtLogin
            && !UserDefaults.standard.bool(forKey: Self.declinedLoginKey)
    }

    /// "Don't ask again", in the invitation.
    func declineOpeningAtLogin() {
        UserDefaults.standard.set(true, forKey: Self.declinedLoginKey)
        Self.log.notice("opening at login declined: no more invitations")
    }

    private static let declinedLoginKey = "declinesOpeningAtLogin"

    // MARK: Notifications

    /// Read from the system every time: the user can change it in System
    /// Settings.
    func refreshNotifications() {
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            setNotifications(status)
        }
    }

    /// Only from the button of the Updates step, or of Settings, next to what
    /// they are for: the system's prompt cannot say it (2026-10-11).
    func requestNotifications() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                Self.log.notice("notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
            } catch {
                Self.log.error("notifications could not be requested: \(error.localizedDescription, privacy: .public)")
            }
            setNotifications(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setNotifications(_ status: UNAuthorizationStatus) {
        notifications = status
        UserDefaults.standard.set(status.rawValue, forKey: Self.notificationsKey)
    }

    private static let notificationsKey = "notificationsStatus"

    // MARK: Permission

    func requestAccess() {
        Task {
            access = await PhotoLibraryAccess.request()
            if access != .notDetermined {
                pendingSaverRequest = nil
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            }
            if access.isGranted { accessGranted() }
        }
    }

    /// Quits and opens again: a Photos grant given in System Settings after a
    /// refusal reaches only a new process.
    func reopen() {
        cancelIndexing()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Self.log.error("could not open Mosaic again: \(error, privacy: .public)")
                } else {
                    MosaicApplication.quitWithoutAsking()
                }
            }
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
        if foreground { loadAlbums() }
        if changes == nil {
            changes = PhotoLibraryChanges { [weak self] in
                Task { @MainActor in self?.libraryChanged() }
            }
        }
        if preferences.source == .photos { startIndexing() }
    }

    /// Only for the window, which lists them: at login the first fetch can
    /// wait minutes for the library to open.
    private func loadAlbums() {
        guard !albumsLoaded else { return }
        albumsLoaded = true
        DispatchQueue.global(qos: .userInitiated).async {
            let started = ProcessInfo.processInfo.systemUptime
            let albums = PhotoLibraryAccess.albumTree()
            let fetched = ProcessInfo.processInfo.systemUptime - started
            Self.log.notice("\(albums.albums.count, privacy: .public) albums fetched in \(fetched, format: .fixed(precision: 2), privacy: .public) s")
            DispatchQueue.main.async {
                let shown = ProcessInfo.processInfo.systemUptime
                self.albums = albums
                // The window lays the list out on the run loop's next pass;
                // this block runs after it.
                DispatchQueue.main.async {
                    let busy = ProcessInfo.processInfo.systemUptime - shown
                    Self.log.notice("albums shown, main thread busy \(busy, format: .fixed(precision: 2), privacy: .public) s")
                }
            }
            // Then the counts without videos, which take seconds more.
            let counting = ProcessInfo.processInfo.systemUptime
            let videos = PhotoLibraryAccess.videoCounts()
            let refined = albums.excludingVideos(videos)
            let counted = ProcessInfo.processInfo.systemUptime - counting
            Self.log.notice("videos counted in \(videos.count, privacy: .public) albums in \(counted, format: .fixed(precision: 2), privacy: .public) s")
            DispatchQueue.main.async { self.albums = refined }
        }
    }

    nonisolated private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

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
        Self.log.notice("the Photos library changed")
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
        clearProblem(at: .preparing)
        restartWhenDone = false
        // Spike 4: with nobody watching, the index waits its turn behind
        // whatever the user is doing — the screen saver included.
        let qos: DispatchQoS.QoSClass = foreground ? .utility : .background
        Self.log.notice("indexing started, \(self.foreground ? "utility" : "background", privacy: .public) QoS")

        // Made here, on the main actor, so the queue's block holds no
        // reference to the model of its own.
        let progressed: @Sendable (IndexProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.progressed(progress) }
        }
        let finished: @Sendable (Error?, Double) -> Void = { [weak self] error, seconds in
            Task { @MainActor in self?.finished(error: error, seconds: seconds) }
        }
        Self.indexQueue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) {
            let started = ProcessInfo.processInfo.systemUptime
            var failure: Error?
            do {
                try Self.index(options: options, flag: flag, progress: progressed)
            } catch {
                failure = error
            }
            finished(failure, ProcessInfo.processInfo.systemUptime - started)
        }
    }

    /// The index, then the .saver's close-ups once the index is whole. The
    /// saver runs without them meanwhile, on enlarged thumbnails.
    nonisolated private static func index(
        options: Options, flag: CancelFlag, progress: @escaping @Sendable (IndexProgress) -> Void
    ) throws {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else { return }
        let builder = PhotoIndexBuilder(
            thumbnailWidth: options.thumbnailWidth, signatureSide: options.signatureSide,
            cropRule: options.cropRule
        )
        let store = PhotoIndexStore(directory: options.resolvedIndexDirectory)
        _ = try builder.build(
            from: indexable.source,
            into: store,
            root: indexable.root,
            progress: progress,
            isCancelled: { flag.isSet }
        )
        guard !flag.isSet else { return }
        log.notice("close-ups started")
        let report = try options.closeUpShelf.stock(
            from: IndexedPhotoSource(store: store, originals: indexable.source),
            isCancelled: { flag.isSet }
        )
        log.notice("""
            close-ups: \(report.made, privacy: .public) made, \(report.kept, privacy: .public) kept, \
            \(report.failed, privacy: .public) failed, \
            \(report.unavailable, privacy: .public) not on this Mac, \(report.removed, privacy: .public) removed
            """)
    }

    func cancelIndexing() {
        restartWhenDone = false
        cancel.set()
    }

    private func progressed(_ progress: IndexProgress) {
        self.progress = progress
        indexedCount = progress.completed - progress.skipped - progress.unavailable
    }

    private func finished(error: Error?, seconds: Double) {
        isIndexing = false
        Self.log.notice("""
            indexing finished in \(seconds, format: .fixed(precision: 1), privacy: .public) s\
            \(error.map { ": \($0)" } ?? "", privacy: .public)
            """)
        if let error {
            report(.preparing, "Preparing the photographs stopped: \(error.localizedDescription)")
        }
        refreshIndexedCount()
        if restartWhenDone {
            startIndexing()
        } else {
            quitIfIdle()
        }
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
                               signatureSide: options.signatureSide, cropRule: options.cropRule)
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
