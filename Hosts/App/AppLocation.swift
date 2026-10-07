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
    @MainActor
    static func moveToApplications() async throws {
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
        log.notice("copied to \(applications.path, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle identifier as this one, which is still running.
        configuration.createsNewApplicationInstance = true
        try await NSWorkspace.shared.openApplication(at: applications, configuration: configuration)
    }

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")
}
