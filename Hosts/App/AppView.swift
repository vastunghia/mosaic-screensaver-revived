import SwiftUI

/// The app's window, laid out for whoever opens it the first time: the steps
/// that lead to the screen saver, in the order they have to happen, each with
/// its state; once they are all done, one section of status in their place.
/// The options are in Settings.
struct AppView: View {
    @ObservedObject var model: AppModel
    let play: () -> Void
    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.isSetUp, !showingSteps {
                    ReadySection(model: model, showSteps: showSteps)
                } else {
                    // Numbered from 1 whether or not the move is one of them.
                    let first = model.isTranslocated ? 2 : 1
                    if model.isTranslocated {
                        LocationStep(model: model, number: 1)
                    }
                    PhotographsStep(model: model, number: first)
                    PreparationStep(model: model, number: first + 1)
                    ScreenSaverStep(model: model, number: first + 2)
                    if model.isSetUp {
                        HStack {
                            Spacer()
                            Button("Hide Setup Steps", action: hideSteps)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
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
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
            model.refreshLoginItem()
            model.refreshSaver()
        }
    }

    private func showSteps() {
        showingSteps = true
    }

    private func hideSteps() {
        showingSteps = false
    }
}
