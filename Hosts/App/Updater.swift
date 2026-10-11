import AppKit
import AppUpdate
import CryptoKit
import Foundation
import Security
import os

/// The app's own updates (2026-10-11): it learns of a newer release on GitHub,
/// prepares it in the background, and installs it when the user says so —
/// never by itself, since an account without administrator rights needs
/// someone at the keyboard anyway to replace the app in Applications.
///
/// What makes a download trustworthy is not the checksum, which sits beside it
/// on the same server, but its signature: the new app has to meet this app's
/// own designated requirement — the same identifier, signed by the same
/// certificate — which is also what keeps the Photos grant across the update.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case preparing(ReleaseVersion)
        /// Downloaded, checked and unpacked: `app` waits to be put in place.
        case ready(Release, app: URL)
        case installing
    }

    enum Outcome {
        case upToDate(ReleaseVersion)
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state = State.idle

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        .flatMap { $0 as? String }.flatMap(ReleaseVersion.init)

    /// Not from where a download was unpacked, which is gone at the next
    /// launch (`AppLocation`), and not for a build without a signature to
    /// compare the new one with (`swift run`).
    var isAvailable: Bool {
        current != nil && !AppLocation.isTranslocated && Self.ownRequirement() != nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .preparing, .installing: true
        case .idle, .ready: false
        }
    }

    var readyRelease: Release? {
        if case .ready(let release, _) = state { release } else { nil }
    }

    private var timer: Timer?

    // MARK: Checking

    /// A check at launch if one is due, then one a day for as long as the app
    /// runs, which as a login item is all the time.
    func start() {
        guard isAvailable, timer == nil else { return }
        removeStale()
        checkIfDue()
        // Hourly, to notice that a day has gone by; a sleeping Mac skips them.
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) >= Self.interval }) ?? true else { return }
        Task { _ = await check(byUser: false) }
    }

    /// Asks the feed for the newest release and, if it is newer, prepares it.
    /// A version the user skipped counts only when the user asks.
    func check(byUser: Bool) async -> Outcome {
        guard let current else { return .failed("this build has no version") }
        if case .ready(let release, _) = state { return .available(release) }
        guard !isBusy else { return .failed("an update is already under way") }
        state = .checking
        let release: Release
        do {
            release = try await fetchRelease()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch {
            state = .idle
            Self.log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        guard current < release.version else {
            state = .idle
            Self.log.notice("up to date: \(current, privacy: .public), newest \(release.version, privacy: .public)")
            return .upToDate(current)
        }
        if !byUser, UserDefaults.standard.string(forKey: Self.skippedKey) == release.version.description {
            state = .idle
            Self.log.notice("\(release.version, privacy: .public) is available, skipped by the user")
            return .upToDate(current)
        }
        state = .preparing(release.version)
        do {
            let app = try await prepare(release)
            state = .ready(release, app: app)
            Self.log.notice("\(release.version, privacy: .public) is ready to install")
            return .available(release)
        } catch {
            state = .idle
            Self.log.error("\(release.version, privacy: .public) could not be prepared: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// GitHub's `releases/latest`, or `-updateFeed <url>` to try updates
    /// against a server of one's own (a single dash: a double one opens the
    /// harness). While the repository is private GitHub answers 404.
    private var feed: URL {
        UserDefaults.standard.string(forKey: "updateFeed").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/vastunghia/mosaic-screensaver-revived/releases/latest")!
    }

    private func fetchRelease() async throws -> Release {
        var request = URLRequest(url: feed, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw UpdateError.server(status, feed)
        }
        return try Release(gitHub: data, app: Self.appName)
    }

    // MARK: Preparing

    /// Downloads the disk image, checks it against its checksum, copies the
    /// app out of it and checks the copy's signature. Kept in the caches until
    /// installed: a second check finds it there.
    private func prepare(_ release: Release) async throws -> URL {
        let folder = Self.updates.appendingPathComponent(release.version.description, isDirectory: true)
        let app = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent, isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: app.path), (try? Self.verify(app, is: release.version)) != nil {
            return app
        }
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let image = folder.appendingPathComponent(release.diskImage.lastPathComponent)
        let (download, response) = try await URLSession.shared.download(from: release.diskImage)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw UpdateError.server(status, release.diskImage)
        }
        try manager.moveItem(at: download, to: image)
        defer { try? manager.removeItem(at: image) }

        if let checksum = release.checksum {
            let (data, _) = try await URLSession.shared.data(from: checksum)
            guard let expected = Checksum.sha256(in: String(decoding: data, as: UTF8.self), for: image.lastPathComponent)
            else { throw UpdateError.noChecksum }
            let actual = try await Task.detached { try Self.sha256(of: image) }.value
            guard actual == expected else { throw UpdateError.checksumMismatch }
        }

        let mount = try await Self.attach(image)
        do {
            let inside = mount.appendingPathComponent(app.lastPathComponent, isDirectory: true)
            try manager.copyItem(at: inside, to: app)
        } catch {
            await Self.detach(mount)
            throw error
        }
        await Self.detach(mount)
        try Self.verify(app, is: release.version)
        return app
    }

    /// What is in the caches and no newer than this app: installed already,
    /// or left behind.
    private func removeStale() {
        guard let current,
              let names = try? FileManager.default.contentsOfDirectory(atPath: Self.updates.path)
        else { return }
        for name in names where ReleaseVersion(name).map({ $0 <= current }) ?? true {
            try? FileManager.default.removeItem(at: Self.updates.appendingPathComponent(name))
        }
    }

    // MARK: Installing

    /// Puts the new app where this one runs, asking for an administrator if
    /// the user cannot write there, and opens it; this one quits. The new one
    /// brings the screen saver up to date (`AppModel.finishUpdate`).
    func install() async throws {
        guard case .ready(let release, let app) = state else { return }
        state = .installing
        do {
            // The caches are the user's to write: once more, just before.
            try Self.verify(app, is: release.version)
            let destination = Bundle.main.bundleURL
            try AppLocation.place(app, at: destination)
            Self.log.notice("installed \(release.version, privacy: .public) over \(self.current?.description ?? "?", privacy: .public)")
            UserDefaults.standard.set(true, forKey: Self.updatedKey)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            try await AppLocation.openAnew(destination)
            MosaicApplication.quitWithoutAsking()
        } catch {
            state = .ready(release, app: app)
            Self.log.error("\(release.version, privacy: .public) could not be installed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// "Skip This Version": not offered again unless the user checks.
    func skip() {
        guard let release = readyRelease else { return }
        UserDefaults.standard.set(release.version.description, forKey: Self.skippedKey)
        Self.log.notice("\(release.version, privacy: .public) skipped by the user")
        try? FileManager.default.removeItem(at: Self.updates.appendingPathComponent(release.version.description))
        state = .idle
    }

    /// Whether replacing the app will ask for an administrator.
    var needsAdministrator: Bool {
        !AppLocation.canWrite(Bundle.main.bundleURL)
    }

    /// Set by the copy that installed an update, read once by the new one.
    static func takeJustUpdated() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: updatedKey) }
        return UserDefaults.standard.bool(forKey: updatedKey)
    }

    // MARK: Private

    private static let appName = "Mosaic"
    private static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdate"
    private static let updatedKey = "justUpdated"
    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "update")

    private static var updates: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.vastunghia.Mosaic", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    /// This app's designated requirement: identifier and certificate.
    private static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The app at `url` is this app, at `version`, sealed and signed as this
    /// one is, every architecture and every nested bundle (the saver).
    private static func verify(_ url: URL, is version: ReleaseVersion) throws {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ReleaseVersion(text) == version
        else { throw UpdateError.notThisApp }
        guard let requirement = ownRequirement() else { throw UpdateError.unsigned }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.unsigned
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.badSignature(status) }
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Mounted read-only, out of sight: no Finder window, nothing on the
    /// desktop, at a path of its own.
    private static func attach(_ image: URL) async throws -> URL {
        let point = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mosaic-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
        let result = try await run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", point.path, image.path,
        ])
        guard result == 0 else {
            try? FileManager.default.removeItem(at: point)
            throw UpdateError.notMounted
        }
        return point
    }

    private static func detach(_ point: URL) async {
        if (try? await run("/usr/bin/hdiutil", ["detach", "-quiet", point.path])) != 0 {
            _ = try? await run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", point.path])
        }
        try? FileManager.default.removeItem(at: point)
    }

    /// A tool's exit status, waited for off the main thread.
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    enum UpdateError: LocalizedError {
        case server(Int, URL)
        case noChecksum
        case checksumMismatch
        case notMounted
        case notThisApp
        case unsigned
        case badSignature(OSStatus)

        var errorDescription: String? {
            switch self {
            case .server(404, _): "no release was found"
            case .server(let status, let url): "the server answered \(status) for \(url.lastPathComponent)"
            case .noChecksum: "the checksum file does not name the disk image"
            case .checksumMismatch: "the download does not match its checksum"
            case .notMounted: "the disk image could not be opened"
            case .notThisApp: "the disk image does not hold this version of Mosaic"
            case .unsigned: "the signature could not be read"
            case .badSignature(let status): "the new version is not signed as this one is (\(status))"
            }
        }
    }
}
