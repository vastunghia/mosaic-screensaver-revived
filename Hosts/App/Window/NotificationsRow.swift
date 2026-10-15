import SwiftUI

/// The state of the permission, and the way to change it: in the setup
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
