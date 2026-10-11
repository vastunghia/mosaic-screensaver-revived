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

/// The state of the permission, and the way to change it: in the Updates step
/// and in Settings.
struct NotificationsRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.notifications {
        case .notDetermined:
            HStack {
                Text("Notifications for new versions")
                Spacer()
                Button("Allow Notifications…", action: model.requestNotifications)
            }
        case .denied:
            HStack {
                Text("Notifications are off: new versions show only in Mosaic’s window")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Notification Settings…", action: model.openNotificationSettings)
            }
        default:
            HStack {
                // The header shows the check mark.
                Text("Notifications allowed, for new versions only")
                Spacer()
                Button("Open Notification Settings…", action: model.openNotificationSettings)
            }
        }
    }
}
