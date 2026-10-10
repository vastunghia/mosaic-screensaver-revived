import SwiftUI

/// Installing the screen saver this app carries, then choosing it.
struct ScreenSaverStep: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        Section {
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
                    // The header already shows the check mark.
                    Text("Installed")
                    Spacer()
                    Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
                }
            }
            ProblemRow(model: model, place: .screenSaver)
        } header: {
            StepHeader(number: number, title: "Screen Saver", isDone: model.saver == .installed)
        } footer: {
            Footnote("Then choose Mosaic in System Settings, under Screen Saver › Other. Mosaic also opens at login, without a window, to keep the photographs up to date; Mosaic Settings turns that off.")
        }
    }
}
