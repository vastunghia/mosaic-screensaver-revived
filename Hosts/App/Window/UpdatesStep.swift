import SwiftUI

/// New versions, and the notification that announces them. The system's
/// prompt says only that Mosaic wants to send notifications: this step says
/// what for before asking, and either answer completes it.
struct UpdatesStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
            NotificationsRow(model: model)
        } header: {
            StepHeader(number: number, title: "Updates", isDone: model.hasAnsweredNotifications)
        } footer: {
            Footnote("Mosaic checks for a new version once a day. Allow notifications so that it can tell you when one is ready, even if you never open this window: they are used for nothing else.")
        }
    }
}
