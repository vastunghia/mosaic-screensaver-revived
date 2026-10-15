import SwiftUI

/// The screen saver this app carries: installed, missing or out of date, with
/// what to do about it. In the window's status and in the setup.
struct SaverRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.saver {
        case .unavailable:
            Text("This build carries no screen saver.")
                .foregroundStyle(.secondary)
        case .notInstalled:
            HStack {
                Text("The screen saver is not installed.")
                Spacer()
                Button("Install…", action: model.installSaver)
            }
        case .different:
            HStack {
                Label("The installed screen saver is not this version.", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Update", action: model.installSaver)
            }
        case .installed:
            HStack {
                Text("Screen saver installed")
                Spacer()
                Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
            }
        }
    }
}
