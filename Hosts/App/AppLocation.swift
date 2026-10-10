import AppKit
import Foundation
import os

/// Where the app runs from, and the move to Applications.
///
/// A downloaded app opened where it was unpacked runs from a random read-only
/// copy (App Translocation), which LaunchServices registers as well and which
/// is gone at the next launch: a login item or a `mosaic://` call bound to it
/// would lead nowhere (2026-10-07). The Finder ends it when the app is moved;
/// this does the move for the user.
enum AppLocation {
    /// There is no public call to ask; the path says it.
    static let isTranslocated = Bundle.main.bundleURL.path.contains("/AppTranslocation/")

    static let applications = URL(fileURLWithPath: "/Applications/\(Bundle.main.bundleURL.lastPathComponent)")

    /// Copies the app into Applications, replacing an older copy, and opens
    /// it there. The caller quits once it has. The download stays where it is:
    /// reaching it would mean asking for the Downloads folder.
    ///
    /// A standard user cannot write to Applications, and dragging there in the
    /// Finder would ask for an administrator anyway: in that case macOS's own
    /// dialog asks for one here (2026-10-10).
    @MainActor
    static func moveToApplications() async throws {
        if canWriteApplications {
            try copyIntoApplications()
        } else {
            try copyIntoApplicationsAsAdministrator()
        }
        log.notice("copied to \(applications.path, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle identifier as this one, which is still running.
        configuration.createsNewApplicationInstance = true
        try await NSWorkspace.shared.openApplication(at: applications, configuration: configuration)
    }

    /// Replacing an older copy also means removing it, so that has to be
    /// allowed too.
    private static var canWriteApplications: Bool {
        let manager = FileManager.default
        let folder = applications.deletingLastPathComponent().path
        return manager.isWritableFile(atPath: folder)
            && (!manager.fileExists(atPath: applications.path) || manager.isWritableFile(atPath: applications.path))
    }

    private static func copyIntoApplications() throws {
        let manager = FileManager.default
        let staging = applications.deletingLastPathComponent()
            .appendingPathComponent(".\(applications.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        try manager.copyItem(at: Bundle.main.bundleURL, to: staging)
        do {
            // The user has let this very code run already.
            try Quarantine.remove(from: staging)
            if manager.fileExists(atPath: applications.path) {
                _ = try manager.replaceItemAt(applications, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: applications)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Stages the copy where the user can write, cleared of quarantine, and
    /// lets only the swap into Applications run as root. `do shell script`
    /// raises the standard administrator dialog, in the name of this app.
    @MainActor
    private static func copyIntoApplicationsAsAdministrator() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("Mosaic-\(UUID().uuidString)", isDirectory: true)
        let staging = folder.appendingPathComponent(applications.lastPathComponent, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        try manager.copyItem(at: Bundle.main.bundleURL, to: staging)
        try Quarantine.remove(from: staging)

        let command = "/bin/rm -rf \(quoted(applications.path)) && /usr/bin/ditto \(quoted(staging.path)) \(quoted(applications.path))"
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"
        var failure: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw MoveError.scriptNotCompiled }
        script.executeAndReturnError(&failure)
        if let failure {
            let number = failure[NSAppleScript.errorNumber] as? Int ?? 0
            let message = failure[NSAppleScript.errorMessage] as? String ?? "unknown error"
            log.error("administrator copy failed (\(number, privacy: .public)): \(message, privacy: .public)")
            // -128: the user cancelled the dialog.
            throw number == -128 ? MoveError.cancelled : MoveError.failed(message)
        }
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A path as one word for the shell.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum MoveError: LocalizedError {
        case scriptNotCompiled
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .scriptNotCompiled: "the administrator request could not be prepared"
            case .cancelled: "no administrator password was given"
            case .failed(let message): message
            }
        }
    }

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")
}
