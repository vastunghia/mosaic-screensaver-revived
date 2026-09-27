import AppKit
import MosaicEngine
import SwiftUI

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate {
    private let engine: MosaicEngine
    private let options: Options
    private let clock = HarnessClock()
    private let readout = HarnessReadout()
    private let ui = HarnessUIState()
    private var window: HarnessWindow?

    init(engine: MosaicEngine, options: Options) {
        self.engine = engine
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        clock.settings = options.settings
        clock.onSettingsChange = { [engine] settings in
            engine.updateSettings(settings)
        }

        let window = HarnessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mosaic — harness"
        window.contentView = NSHostingView(
            rootView: HarnessView(engine: engine, clock: clock, readout: readout, ui: ui)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        if options.fullScreen {
            window.toggleFullScreen(nil)
        }
        window.clock = clock
        window.ui = ui
        window.engine = engine
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        if let interval = options.rebuildEvery {
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [engine] _ in
                engine.rebuild()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
