import AppKit
import SharedStore
import SwiftUI
import os

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
        // .accessory until a window opens: launched at login there is none,
        // and no Dock icon either.
        application.setActivationPolicy(.accessory)
        application.run()
        exit(0)
    }

    static func mainMenu() -> NSMenu {
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

/// How the app was launched decides whether it shows a window (spike 4).
///
/// By hand — the Finder, `open` — or with `mosaic://open`, someone wants the
/// window. At login (the `oapp` event says `lgit`) or with `mosaic://update`
/// from the .saver, nobody is there: the app brings the index up to date
/// without a window and, while it is a login item, stays to watch the library.
/// `LSUIElement` keeps it out of the Dock until a window opens.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?

    private var launchedAtLogin = false
    /// URLs that arrive before the model exists, during launch.
    private var earlyCalls: [MosaicURL] = []

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch event arrives after this and before
        // applicationDidFinishLaunching, so it is read in a handler: no event
        // is current here yet, and by applicationDidFinishLaunching it is gone.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openApplication(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication)
        )
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wantsWindow = !launchedAtLogin && (earlyCalls.isEmpty || earlyCalls.contains(.open))
        let launch = launchedAtLogin ? "at login" : earlyCalls.isEmpty ? "by hand"
            : earlyCalls.map { "\($0.url)" }.joined(separator: ", ")
        Self.log.notice("launched \(launch, privacy: .public), \(wantsWindow ? "with" : "without", privacy: .public) a window")

        let model = AppModel(foreground: wantsWindow)
        self.model = model
        if wantsWindow { showWindow() }
        if launchedAtLogin { model.updateRequested(reason: "login") }
        for call in earlyCalls { handle(call) }
        earlyCalls = []
    }

    /// `oapp` says `lgit` when the app is launched as a login item.
    @objc private func openApplication(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        launchedAtLogin = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), let call = MosaicURL(url)
        else {
            Self.log.notice("ignored a URL that is not ours")
            return
        }
        if model == nil {
            earlyCalls.append(call)
        } else {
            Self.log.notice("called with \(call.url, privacy: .public)")
            handle(call)
        }
    }

    private func handle(_ call: MosaicURL) {
        switch call {
        case .open: showWindow()
        case .update(let reason): model?.updateRequested(reason: reason)
        }
    }

    /// Double-clicked in the Finder while running without a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    private func showWindow() {
        guard let model else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            NSApp.mainMenu = MosaicApplication.mainMenu()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mosaic"
            window.isReleasedWhenClosed = false
            window.delegate = self
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
            self.window = window
        }
        Self.log.notice("window shown")
        model.windowOpened()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A login item outlives its window, to keep watching the library; an app
    /// that is not one quits with it, as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let model else { return true }
        model.refreshLoginItem()
        return !model.opensAtLogin
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        model.refreshLoginItem()
        if model.opensAtLogin {
            model.windowClosed()
            Self.log.notice("window closed; staying in the background as a login item")
            // Back out of the Dock, after the window has gone.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
