import AppKit
import SwiftUI

/// M9 as a user sees it: launched with no flags — from the Finder, or with a
/// bare `open Mosaic.app` — the app opens its own window instead of the
/// harness. Any flag keeps the harness exactly as it was, so every export and
/// specimen regenerates byte for byte.
@MainActor
enum MosaicApplication {
    /// Whether the command line asks for the harness. Launch Services may add
    /// arguments of its own (`-psn_…`, `-NSDocumentRevisionsDebugMode`); only a
    /// double-dash flag is ours.
    static func wantsHarness(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    private static var delegate: AppDelegate?

    static func run() -> Never {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.mainMenu = mainMenu()
        application.run()
        exit(0)
    }

    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Mosaic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mosaic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        return menu
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mosaic"
        window.contentView = NSHostingView(rootView: AppView(model: model) { [weak window, weak model] in
            guard let model else { return }
            do {
                try Player.play(preferences: model.preferences, on: window?.screen)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The mosaic could not start."
                alert.informativeText = "\(error)"
                alert.runModal()
            }
        })
        window.setFrameAutosaveName("Mosaic")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
