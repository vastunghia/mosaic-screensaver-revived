import SwiftUI

/// The top of the window: the mosaic itself, moving, and Full Screen on it. Before
/// there are photographs enough, the icon's mosaic in its place.
struct PreviewSection: View {
    @ObservedObject var model: AppModel
    let play: () -> Void

    var body: some View {
        Section {
            ZStack(alignment: .bottomTrailing) {
                // The index on disk is enough, as for the screen saver: also
                // while the Photos grant is missing, which full screen needs.
                if model.hasIndex {
                    // A button only while it can play: otherwise a click,
                    // or VoiceOver's action, would do nothing at all.
                    let preview = LivePreview(preferences: model.preferences, isReady: model.hasIndex,
                                              play: model.canPlay ? play : nil)
                        .accessibilityLabel("Preview of the mosaic")
                    if model.canPlay {
                        preview
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: "Full Screen", play)
                    } else {
                        preview
                    }
                    // Full screen needs the library, for its close-ups. Without
                    // it the button is not shown: disabled over a moving
                    // mosaic it could not be read, and the status below says why.
                    if model.canPlay {
                        // Dark rather than the accent colour, which some
                        // photographs under it would share.
                        // Not "Play": the mosaic already runs here, and the
                        // button only takes it full screen (Sergio, 2026-10-15).
                        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: play)
                            .buttonStyle(.borderedProminent)
                            .tint(.black.opacity(0.6))
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
                    .help("Rows, zoom duration, the photographs to use and updates (⌘,)")
                Spacer()
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
