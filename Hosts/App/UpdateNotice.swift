import AppUpdate
import Foundation
import UserNotifications
import os

/// The notification that an update is ready (2026-10-11). Most people let
/// Mosaic open at login and never open its window again: the sheet would
/// wait for them for ever, so the update is announced where they will see it.
///
/// The permission is asked for while a window is open and Mosaic opens at
/// login — the one case that needs it, and a moment when the prompt has a
/// reason the user can see. Never from the background.
@MainActor
enum UpdateNotice {
    static func requestPermissionIfUseful(opensAtLogin: Bool) {
        guard opensAtLogin else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                log.notice("notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
            } catch {
                log.error("notifications could not be requested: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Once a version: a click on it opens the window, with the update.
    static func post(_ release: Release) {
        let version = release.version.description
        guard UserDefaults.standard.string(forKey: notifiedKey) != version else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else {
                log.notice("\(version, privacy: .public) is ready, but notifications are not allowed")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Mosaic \(version) is available"
            content.body = "Click to see what’s new and install it."
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                UserDefaults.standard.set(version, forKey: notifiedKey)
                log.notice("\(version, privacy: .public) announced in a notification")
            } catch {
                log.error("the notification could not be posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Once the update has been offered in the window, or is gone.
    static func withdraw() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// One at a time: a newer version replaces the older one's.
    nonisolated static let identifier = "update"
    private static let notifiedKey = "notifiedUpdate"
    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "update")
}
