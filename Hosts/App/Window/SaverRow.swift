import SwiftUI

/// The screen saver this app carries: installed, missing or out of date, with
/// what to do about it. In the window's status and in the setup.
struct SaverRow: View {
    @ObservedObject var model: AppModel
    /// Off in the setup, which shows where to choose it at its end.
    var showingSettings = true

    var body: some View {
        switch model.saver {
        case .unavailable:
            Text("This build carries no screen saver.")
                .foregroundStyle(.secondary)
        case .notInstalled:
            HStack {
                Text("The screen saver is not installed.")
                Spacer()
                Button("Install…", action: install)
            }
        case .different:
            HStack {
                Label("The installed screen saver is not this version.", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Update", action: install)
            }
        case .installed:
            HStack {
                Text("Screen saver installed")
                Spacer()
                Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
            }
        }
    }

    private func install() {
        model.installSaver(showingSettings: showingSettings)
    }
}
