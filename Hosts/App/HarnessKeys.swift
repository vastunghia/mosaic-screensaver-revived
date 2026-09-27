import AppKit
import MosaicEngine

/// A window that reads the keyboard before its contents do.
///
/// SwiftUI's `onKeyPress` needs the view to hold the focus, and in a window full
/// of sliders it never does — the first slider takes it, and then space belongs
/// to the slider rather than to the effect. Intercepting in `sendEvent` sidesteps
/// focus entirely, which is what a harness wants: the keys have to work on a full
/// screen with every control hidden.
@MainActor
final class HarnessWindow: NSWindow {
    var clock: HarnessClock?
    var ui: HarnessUIState?
    var engine: MosaicEngine?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let clock, let ui else { return false }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1

        switch event.keyCode {
        case 49: clock.isPaused.toggle()      // space
        case 123: clock.step(frames: -step)   // left
        case 124: clock.step(frames: step)    // right
        case 126: clock.jumpCycles(1)         // up
        case 125: clock.jumpCycles(-1)        // down
        default:
            switch event.charactersIgnoringModifiers {
            case "f": toggleFullScreen(nil)
            case "h": ui.showsControls.toggle()
            case "r": clock.reset()
            // Throws away every GPU resource and makes it again: the path an
            // unplugged eGPU takes, exercised without unplugging anything.
            case "g": engine?.rebuild()
            default: return false
            }
        }
        return true
    }
}

@MainActor
final class HarnessUIState: ObservableObject {
    @Published var showsControls = true
}
