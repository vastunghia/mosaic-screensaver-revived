import Foundation
import MosaicCore

/// Time, owned by the host.
///
/// The engine has no clock of its own — it is handed an absolute time and draws
/// what belongs to it. That is what makes scrubbing possible here, and it is
/// also what the screen saver will need, since its host drives the frames.
@MainActor
final class HarnessClock: ObservableObject {
    @Published var settings = MosaicSettings() {
        didSet { onSettingsChange?(settings) }
    }

    /// Deliberately *not* @Published. It changes 60 times a second, and a
    /// publisher here redraws the whole control panel at 60 Hz: the harness
    /// would then spend more of the CPU than the effect does, and the numbers it
    /// shows would be measuring itself. The overlay reads the time back from the
    /// engine's statistics instead, a few times a second.
    private(set) var time: TimeInterval = 0

    @Published var isPaused = false

    var onSettingsChange: ((MosaicSettings) -> Void)?

    /// Position within the current cycle, 0...1. Setting it scrubs.
    var u: Double {
        get {
            let cycles = time / settings.cycleDuration
            return cycles - cycles.rounded(.down)
        }
        set {
            let index = (time / settings.cycleDuration).rounded(.down)
            time = (index + min(max(newValue, 0), 0.999_999)) * settings.cycleDuration
        }
    }

    var cycleIndex: Int {
        Int((time / settings.cycleDuration).rounded(.down))
    }

    func advance(by delta: TimeInterval) {
        guard !isPaused else { return }
        time += delta
    }

    func step(frames: Double, at rate: Double = 60) {
        isPaused = true
        time = max(0, time + frames / rate)
    }

    func jumpCycles(_ count: Int) {
        time = max(0, time + Double(count) * settings.cycleDuration)
    }

    func reset() {
        time = 0
    }
}
