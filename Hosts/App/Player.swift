import AppKit
import Metal
import MosaicEngine
import SwiftUI

/// The effect full screen, as the saver will run it: the same engine, the same
/// planner, a new seed each time, and nothing on screen but the mosaic. A key
/// or a click ends it, as it ends a screen saver.
@MainActor
enum Player {
    private static var window: PlayerWindow?

    static func play(preferences: AppPreferences, on screen: NSScreen?) throws {
        try play(options: preferences.options(), on: screen)
    }

    /// Also the harness's `--play`, which is how the effect is measured as a
    /// user sees it.
    static func play(options: Options, on screen: NSScreen?, onEnd: (() -> Void)? = nil) throws {
        guard window == nil else { return }
        let screen = screen ?? NSScreen.main

        // The GPU that drives the display it will be shown on: on a machine
        // with an eGPU the system default is not necessarily it.
        let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
        guard let device = display.flatMap(CGDirectDisplayCopyCurrentMetalDevice)
            ?? MTLCreateSystemDefaultDevice()
        else {
            throw HarnessError.noMetalDevice
        }

        let engine = try EngineFactory.make(options: options, device: device)
        let clock = HarnessClock()
        clock.settings = options.settings
        let player = PlayerWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        player.contentView = NSHostingView(
            rootView: MosaicView(engine: engine, clock: clock, readout: HarnessReadout(), drawableScale: options.drawableScale)
                .ignoresSafeArea()
                .background(.black)
        )
        player.backgroundColor = .black
        player.level = .screenSaver
        player.isReleasedWhenClosed = false
        player.onEnd = {
            NSCursor.unhide()
            window?.orderOut(nil)
            window = nil
            onEnd?()
        }
        if let screen { player.setFrame(screen.frame, display: true) }
        player.makeKeyAndOrderFront(nil)
        NSCursor.hide()
        window = player
    }
}

@MainActor
final class PlayerWindow: NSWindow {
    var onEnd: (() -> Void)?
    private var shownAt = Date()

    override var canBecomeKey: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        shownAt = Date()
        super.makeKeyAndOrderFront(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown:
            // The click that pressed Play must not also end it.
            if Date().timeIntervalSince(shownAt) > 0.5 { onEnd?() }
        default:
            super.sendEvent(event)
        }
    }
}
