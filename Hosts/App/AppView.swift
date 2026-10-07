import SwiftUI

/// The app's one window, laid out for whoever opens it the first time: the
/// steps that lead to the screen saver, in the order they have to happen,
/// each with its state, then the options, then Play.
struct AppView: View {
    @ObservedObject var model: AppModel
    let play: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // Numbered from 1 whether or not the move is one of them.
                let first = model.isTranslocated ? 2 : 1
                if model.isTranslocated {
                    LocationStep(model: model, number: 1)
                }
                PhotographsStep(model: model, number: first)
                IndexStep(model: model, number: first + 1)
                ScreenSaverStep(model: model, number: first + 2)

                if model.preferences.source == .photos, model.access.isGranted {
                    LibraryOptions(model: model)
                }
                MosaicOptions(model: model)
                LoginItemOption(model: model)
            }
            .formStyle(.grouped)

            HStack {
                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .font(.callout)
                }
                Spacer()
                Button("Play", action: play)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPlay)
                    .help(model.canPlay
                          ? "Full screen. Any key or click ends it."
                          : "Needs at least \(AppModel.minimumPhotographs) indexed photographs.")
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 760)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
            model.refreshLoginItem()
            model.refreshSaver()
        }
    }
}
