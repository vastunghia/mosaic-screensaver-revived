import SwiftUI

/// The app's window: the mosaic itself, moving, and under it what the screen
/// saver has and still needs, with what to do about it. The guided setup has a
/// window of its own; the options are in Settings.
struct AppView: View {
    @ObservedObject var model: AppModel
    let updater: Updater
    let play: () -> Void

    var body: some View {
        Form {
            PreviewSection(model: model, play: play)
            StatusSection(model: model, updater: updater)
            LoginItemOption(model: model)
        }
        .formStyle(.grouped)
        // As tall as what it shows — the window follows as rows come and
        // go — but never taller than the screen: past that, it scrolls.
        .frame(width: 520)
        .frame(maxHeight: Self.tallest)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
            model.refreshLoginItem()
            model.refreshSaver()
            model.refreshNotifications()
        }
    }

    /// The screen's usable height, less the title bar.
    private static var tallest: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 40
    }
}
