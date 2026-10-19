import AppKit
import Darwin
import Foundation
import Security
import os

/// Puts the .saver the app carries into `~/Library/Screen Savers` (milestone 5:
/// the screen saver is installed from the app).
///
/// The app and the saver are built together and share the index format, so
/// the copy that counts is the one inside the app: what is installed is
/// compared with it by the code directory hash of its signature, which changes
/// with every build that changes the code and with nothing else.
@MainActor
enum SaverInstaller {
    enum State: Equatable {
        /// This app carries no saver: a bare `swift run`, not the bundle.
        case unavailable
        case notInstalled
        /// Installed, but not the copy this app carries.
        case different
        case installed
    }

    static let saverName = "Mosaic.saver"

    static var bundled: URL? {
        Bundle.main.url(forResource: "Mosaic", withExtension: "saver")
    }

    /// For this user only: nothing to authorise, and the saver reads the
    /// index of this user anyway.
    static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent(saverName, isDirectory: true)
    }

    static var state: State {
        guard let bundled, let carried = codeHash(of: bundled) else { return .unavailable }
        guard FileManager.default.fileExists(atPath: installed.path) else { return .notInstalled }
        return codeHash(of: installed) == carried ? .installed : .different
    }

    /// Copies the saver in, replacing whatever was there in one step, and
    /// once the new one can be loaded calls `ready`.
    static func install(ready: @escaping @MainActor () -> Void) throws {
        guard let bundled else { return }
        let manager = FileManager.default
        let folder = installed.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let replacing = manager.fileExists(atPath: installed.path)
        // Copied next to its destination first, so the swap is a rename on
        // one volume and a saver half copied is never in place.
        let staging = folder.appendingPathComponent(".\(saverName).\(UUID().uuidString)", isDirectory: true)
        try manager.copyItem(at: bundled, to: staging)
        do {
            try Quarantine.remove(from: staging)
            if replacing {
                _ = try manager.replaceItemAt(installed, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: installed)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        log.notice("screen saver \(replacing ? "updated" : "installed", privacy: .public) in \(installed.path, privacy: .public)")
        if replacing { restartHost(then: ready) } else { ready() }
    }

    /// The pane where Mosaic is chosen. macOS 26 has no Screen Saver pane: the
    /// screen saver is chosen in a sheet behind the Wallpaper pane's Screen
    /// Saver button, which no link reaches, and the old link lands on General
    /// (2026-10-10).
    static func openSettings() {
        let pane = if #available(macOS 26, *) {
            "com.apple.Wallpaper-Settings.extension"
        } else {
            "com.apple.ScreenSaver-Settings.extension"
        }
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where in System Settings Mosaic is chosen, for the window's footnotes.
    static var whereToChoose: String {
        if #available(macOS 26, *) {
            String(localized: "Wallpaper › Screen Saver › Other",
                   comment: "Path in System Settings on macOS 26: the exact names macOS uses for the Wallpaper pane, its Screen Saver button and the Other section")
        } else {
            String(localized: "Screen Saver › Other",
                   comment: "Path in System Settings on macOS 15: the exact names macOS uses for the Screen Saver pane and its Other section")
        }
    }

    // MARK: Private

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

    private static func codeHash(of bundle: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }

    /// `legacyScreenSaver` keeps the saver it has loaded until it exits, and
    /// outlives every run (spike 4): without this, the old code would go on
    /// running — in the preview at once, in the screen saver until the next
    /// logout. It is started again on demand. Never while the screen saver is
    /// showing, which a click in this app rules out anyway.
    ///
    /// System Settings does not start it again for a pane it is showing: the
    /// preview stayed black after the update (2026-10-07). So System Settings
    /// quits first, and `ready` opens the pane afresh.
    private static func restartHost(then ready: @escaping @MainActor () -> Void) {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
        guard !running else {
            log.notice("the screen saver is running: the old one stays loaded until it exits")
            ready()
            return
        }
        let settings = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.systempreferences"
        }
        settings.forEach { $0.terminate() }
        waitUntil(deadline: ProcessInfo.processInfo.systemUptime + 3, { settings.allSatisfy(\.isTerminated) }) {
            for pid in processes(named: "legacyScreenSaver") {
                kill(pid, SIGTERM)
                log.notice("stopped legacyScreenSaver \(pid, privacy: .public), which held the old screen saver")
            }
            ready()
        }
    }

    /// Polls on the main queue without blocking it.
    private static func waitUntil(
        deadline: TimeInterval, _ condition: @escaping @MainActor () -> Bool, then action: @escaping @MainActor () -> Void
    ) {
        if condition() || ProcessInfo.processInfo.systemUptime > deadline {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { waitUntil(deadline: deadline, condition, then: action) }
        }
    }

    /// This user's processes with that name.
    private static func processes(named name: String) -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
                  info.pbsi_uid == getuid()
            else { return false }
            // Not pbsi_comm, which keeps 16 characters: legacyScreenSaver has 17.
            var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self) == name
        }
    }
}
