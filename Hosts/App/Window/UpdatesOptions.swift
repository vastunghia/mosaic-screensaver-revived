import SwiftUI

/// New versions, in Settings: how Mosaic says one is ready. Seldom changed,
/// so it lives here rather than in the window.
struct UpdatesOptions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            NotificationsRow(model: model)
        } header: {
            Text("Updates")
        } footer: {
            Footnote("Mosaic checks for a new version once a day. Notifications tell you only that one is ready, even if you never open its window.")
        }
    }
}
