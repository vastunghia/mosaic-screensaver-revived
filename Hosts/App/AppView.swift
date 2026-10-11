import SwiftUI

/// The app's window, laid out for whoever opens it the first time: the steps
/// that lead to the screen saver, in the order they have to happen, each with
/// its state; once they are all done, one section of status in their place.
/// Above them, the mosaic itself. The options are in Settings.
struct AppView: View {
    @ObservedObject var model: AppModel
    let updater: Updater
    let play: () -> Void
    @State private var showingSteps = false

    var body: some View {
        Form {
            PreviewSection(model: model, play: play, stepsToggle: stepsToggle)
            if model.isSetUp, !showingSteps {
                ReadySection(model: model, updater: updater)
            } else {
                // Numbered from 1 whether or not the move is one of them.
                let first = model.isTranslocated ? 2 : 1
                if model.isTranslocated {
                    LocationStep(model: model, number: 1)
                }
                PhotographsStep(model: model, number: first)
                PreparationStep(model: model, number: first + 1)
                ScreenSaverStep(model: model, number: first + 2)
                UpdatesStep(model: model, number: first + 3)
            }
        }
        .formStyle(.grouped)
        // As tall as what it shows — the window follows, as the steps fold and
        // unfold — but never taller than the screen: past that, it scrolls.
        .frame(width: 520)
        .frame(maxHeight: Self.tallest)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
            model.refreshLoginItem()
            model.refreshSaver()
            model.refreshNotifications()
        }
    }

    /// The screen's usable height, less the title bar.
    private static var tallest: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 40
    }

    private var stepsToggle: PreviewSection.StepsToggle? {
        guard model.isSetUp else { return nil }
        return PreviewSection.StepsToggle(showing: showingSteps, action: toggleSteps)
    }

    private func toggleSteps() {
        showingSteps.toggle()
    }
}
