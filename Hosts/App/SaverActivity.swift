import AppKit
import os

/// Whether a screen saver is running, as far as the app can tell.
///
/// The saver reads a thumbnail and a close-up at every cycle, from the index it
/// started with, so the files of a subset no longer in use are removed only
/// once it has stopped (`IndexHousekeeping`). The system says so with two
/// distributed notifications, `com.apple.screensaver.didstart` and `didstop`:
/// measured on macOS 15.7 from a hot corner and from `open -a
/// ScreenSaverEngine` (2026-10-19). The process says nothing: from a hot
/// corner there is no ScreenSaverEngine, and `legacyScreenSaver`, which hosts
/// the saver, outlives it.
///
/// Before the first notification nothing is known, and the saver is taken
/// to be stopped: the app is opened by someone at the screen, or at login.
/// Called by the saver itself (`mosaic://update`), it is taken to be running
/// until it stops or a window opens.
@MainActor
final class SaverActivity {
    private(set) var isRunning = false
    /// Called each time a saver stops.
    var onStop: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.notice("a screen saver started")
                self?.isRunning = true
            }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.log.notice("a screen saver stopped")
                self.isRunning = false
                self.onStop?()
            }
        })
    }

    /// The saver called: it is running now, whatever was heard before.
    func calledBySaver() {
        isRunning = true
    }

    /// Someone opened a window, so no saver covers the screen.
    func windowOpened() {
        isRunning = false
    }
}
