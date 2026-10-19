import AppKit
import PhotoIndex
import SwiftUI

/// Resets the caps on what Mosaic downloads from iCloud, once they hold
/// close-ups back. They protect the user's disk and maybe their bill, so
/// nothing happens until the user has read what lifting them costs and said
/// yes (Sergio, 2026-10-13); Cancel is the default.
struct DownloadLimitsReset: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Reset Limits…", action: confirm)
            .disabled(!model.canResetDownloadLimits)
    }

    private func confirm() {
        guard let waiting = model.closeUpsWaiting else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the download limits?", comment: "Alert title")
        alert.informativeText = Self.cost(waiting: waiting.count + waiting.ring)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Reset Limits", comment: "Alert button: resets the download limits"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let model = model
        let answered: (NSApplication.ModalResponse) -> Void = { answer in
            guard answer == .alertFirstButtonReturn else { return }
            model.resetDownloadLimits()
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    /// What the reset lets through at once, and what it weighs: 1.3 MB a
    /// close-up, as the downloads sheet says (1.26 measured, 2026-10-13).
    static func cost(waiting: Int) -> String {
        let daily = DownloadLedger.standardDailyLimit
        let weekly = DownloadLedger.standardWeeklyLimit
        let now = min(waiting, daily)
        let megabytes = Int((Double(now) * 1.3).rounded())
        let why = String(localized: """
            Mosaic downloads at most \(daily) copies a day and \(weekly) a week, to \
            protect the space on this Mac and your network data.
            """, comment: "Reset the download limits: the first paragraph, what the limits are for")
        let what = now == waiting
            ? String(localized: """
                If you reset the limits, Mosaic counts from zero and right away downloads the \(now) still missing, \
                about \(megabytes) MB. On a plan that charges for data, they count toward it. \
                Photos keeps them in your library until it needs the space.
                """, comment: "Reset the download limits: what a reset downloads, when it is all that is missing")
            : String(localized: """
                If you reset the limits, Mosaic counts from zero and right away downloads \(now) of the \(waiting) still missing, \
                about \(megabytes) MB, and the others as the limits allow. On a plan that charges for data, they count toward it. \
                Photos keeps them in your library until it needs the space.
                """, comment: "Reset the download limits: what a reset downloads at once, of all that is missing")
        let after = String(localized: "The limits apply again from now on.",
                           comment: "Reset the download limits: the last paragraph")
        return [why, what, after].joined(separator: "\n\n")
    }
}
