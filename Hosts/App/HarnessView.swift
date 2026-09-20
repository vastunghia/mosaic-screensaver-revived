import MosaicCore
import MosaicEngine
import SwiftUI

/// The harness: the effect, plus the controls needed to judge it.
///
/// The judgement this milestone exists to make is about how the movement feels,
/// and that cannot be made from a document. It needs R and T changeable while
/// watching, the ability to stop and rewind to the same instant twice, and a
/// full screen with nothing else on it.
struct HarnessView: View {
    let engine: MosaicEngine
    @ObservedObject var clock: HarnessClock
    @ObservedObject var readout: HarnessReadout

    @State private var showsControls = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            MosaicView(engine: engine, clock: clock, readout: readout)
                .ignoresSafeArea()

            if showsControls {
                VStack(alignment: .leading, spacing: 12) {
                    statistics
                    controls
                }
                .padding(14)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: 380, alignment: .leading)
            }
        }
        .background(.black)
        .onKeyPress { press in handle(press) }
        .focusable()
        .focusEffectDisabled()
    }

    private var statistics: some View {
        let stats = readout.statistics
        return VStack(alignment: .leading, spacing: 2) {
            // The GPU's name sits next to its numbers on purpose: this machine
            // has two very different ones, and an unlabelled frame time means
            // nothing.
            Text(stats.deviceName.isEmpty ? "—" : stats.deviceName)
                .font(.system(size: 11, weight: .semibold))
            Text(String(
                format: "%.0f fps · %.2f ms GPU · %d tiles",
                readout.framesPerSecond, stats.gpuMilliseconds, stats.tileCount
            ))
            Text(String(format: "cycle %d · u = %.3f", stats.cycleIndex, stats.u))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("rows R", value: "\(clock.settings.rows)") {
                Slider(
                    value: Binding(
                        get: { Double(clock.settings.rows) },
                        set: { clock.settings.rows = Int($0.rounded()) }
                    ),
                    in: 4...60,
                    step: 1
                )
            }

            labelled("duration T", value: String(format: "%.0f s", clock.settings.cycleDuration)) {
                Slider(
                    value: Binding(
                        get: { clock.settings.cycleDuration },
                        set: { clock.settings.cycleDuration = $0 }
                    ),
                    in: 4...60
                )
            }

            labelled("crossfade", value: String(format: "%.2f u", clock.settings.crossfadeDuration)) {
                Slider(
                    value: Binding(
                        get: { clock.settings.crossfadeDuration },
                        set: { clock.settings.crossfadeDuration = max(0.01, min($0, 1)) }
                    ),
                    in: 0.01...0.5
                )
            }

            labelled("scrub u", value: String(format: "%.3f", readout.statistics.u)) {
                Slider(
                    value: Binding(
                        get: { readout.statistics.u },
                        set: { clock.isPaused = true; clock.u = $0 }
                    ),
                    in: 0...1
                )
            }

            HStack(spacing: 8) {
                Button(clock.isPaused ? "▶︎" : "❚❚") { clock.isPaused.toggle() }
                Button("◀︎ 1f") { clock.step(frames: -1) }
                Button("1f ▶︎") { clock.step(frames: 1) }
                Button("cycle −") { clock.jumpCycles(-1) }
                Button("cycle +") { clock.jumpCycles(1) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("space pause · ←/→ one frame · f full screen · h hide")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 11, design: .monospaced))
        .tint(.white)
    }

    private func labelled(
        _ name: String,
        value: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text(value).monospacedDigit()
            }
            control()
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            clock.isPaused.toggle()
        case .leftArrow:
            clock.step(frames: press.modifiers.contains(.shift) ? -10 : -1)
        case .rightArrow:
            clock.step(frames: press.modifiers.contains(.shift) ? 10 : 1)
        case KeyEquivalent("f"):
            NSApp.keyWindow?.toggleFullScreen(nil)
        case KeyEquivalent("h"):
            showsControls.toggle()
        case KeyEquivalent("r"):
            clock.reset()
        default:
            return .ignored
        }
        return .handled
    }
}
