import SwiftUI

/// Whether the app keeps the index fresh on its own, in the window: it decides
/// whether the screen saver's photographs follow the library, which is the
/// window's business more than a setting's. The system's word is the truth:
/// the user can switch it off in System Settings.
struct LoginItemOption: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            // One row of a grouped form (HIG, Toggles: mini switch).
            .controlSize(.mini)
            .disabled(model.isTranslocated)
            if model.loginItem == .requiresApproval {
                HStack {
                    Text("Waiting for approval in System Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…", action: model.openLoginItemsSettings)
                }
            }
            ProblemRow(model: model, place: .background)
        } header: {
            Text("In the Background")
        } footer: {
            Footnote(model.isTranslocated
                 ? "Available once Mosaic is in Applications."
                 : model.opensAtLogin
                    ? "Mosaic opens at login without a window and keeps the screen saver’s photographs up to date."
                    : "Mosaic keeps the screen saver’s photographs up to date only while it is open.")
        }
    }
}
