import SwiftUI

/// Whether the app keeps the index fresh on its own. The system's word is the
/// truth: the user can switch it off in System Settings.
struct LoginItemOption: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            .disabled(model.isTranslocated)
            if model.loginItem == .requiresApproval {
                HStack {
                    Text("Waiting for approval in System Settings")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…", action: model.openLoginItemsSettings)
                }
            }
            ProblemRow(model: model, place: .settings)
        } header: {
            Text("In the Background")
        } footer: {
            Footnote(model.isTranslocated
                 ? "Available once Mosaic is in Applications."
                 : "Mosaic runs without a window and keeps the screen saver's photographs up to date.")
        }
    }
}
