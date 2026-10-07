import SwiftUI

/// `PreviewMetalView` in SwiftUI. It builds a new engine only when
/// `preferences` or `isReady` change — not when SwiftUI merely redraws.
struct LivePreview: NSViewRepresentable {
    let preferences: AppPreferences
    let isReady: Bool
    let play: () -> Void

    func makeNSView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        view.onClick = play
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PreviewMetalView, context: Context) {
        view.onClick = play
        configure(view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var built: (AppPreferences, Bool)?
    }

    private func configure(_ view: PreviewMetalView, coordinator: Coordinator) {
        if let built = coordinator.built, built.0 == preferences, built.1 == isReady { return }
        coordinator.built = (preferences, isReady)
        guard isReady else {
            view.makeEngine = nil
            return
        }
        // As the screen saver's preview: few photographs, no close-ups.
        var options = preferences.options()
        options.poolSize = 256
        let chosen = options
        view.makeEngine = { device in try EngineFactory.makePreview(options: chosen, device: device) }
    }
}
