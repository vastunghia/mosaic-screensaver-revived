import SwiftUI

/// The top of the window: the mosaic itself, moving, and Play on it. Before
/// there are photographs enough, the icon's mosaic in its place.
struct PreviewSection: View {
    @ObservedObject var model: AppModel
    let play: () -> Void
    let stepsToggle: StepsToggle?

    /// Shown once every step is done: the steps fold into one section of
    /// status, and come back on request.
    struct StepsToggle {
        let showing: Bool
        let action: () -> Void
    }

    var body: some View {
        Section {
            ZStack(alignment: .bottomTrailing) {
                // The index on disk is enough, as for the screen saver: also
                // while the Photos grant is missing, which Play needs.
                if model.hasIndex {
                    LivePreview(preferences: model.preferences, isReady: model.hasIndex, play: play)
                        .accessibilityLabel("Preview of the mosaic")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Play", play)
                    // Full screen needs the library, for its close-ups. Without
                    // it the button is not shown: disabled over a moving
                    // mosaic it could not be read, and the step above says why.
                    if model.canPlay {
                        Button("Play", systemImage: "play.fill", action: play)
                            .buttonStyle(.borderedProminent)
                            .padding()
                            .help("Full screen. Any key or click ends it.")
                    }
                } else {
                    Waiting()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            .listRowInsets(EdgeInsets())
        } footer: {
            HStack {
                // Under the mosaic it changes, so the options are found where
                // they act; the menu item and ⌘, open the same window.
                Button("Mosaic Settings…", systemImage: "gearshape", action: MosaicApplication.showSettings)
                    .help("Rows, zoom duration and the photographs to use (⌘,)")
                Spacer()
                if let stepsToggle {
                    Button(stepsToggle.showing ? "Hide Setup Steps" : "Show Setup Steps", action: stepsToggle.action)
                        .buttonStyle(.link)
                }
            }
        }
    }

    /// Before the effect can run.
    private struct Waiting: View {
        var body: some View {
            ZStack {
                Color.black
                VStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("The mosaic appears here once \(AppModel.minimumPhotographs) photographs are ready.")
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
    }
}
