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
                if model.canPlay {
                    LivePreview(preferences: model.preferences, isReady: model.canPlay, play: play)
                        .accessibilityLabel("Preview of the mosaic")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Play", play)
                    Button("Play", systemImage: "play.fill", action: play)
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .help("Full screen. Any key or click ends it.")
                } else {
                    Waiting()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            .listRowInsets(EdgeInsets())
        } footer: {
            if let stepsToggle {
                HStack {
                    Spacer()
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
