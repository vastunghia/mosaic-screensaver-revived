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

    /// Quits without the warning a login item gives: for the app's own
    /// restarts, which open it again straight away.
    static func quitWithoutAsking() {
        delegate?.asksBeforeQuitting = false
        NSApp.terminate(nil)
    }

    /// One place of the user guide, for a help button.
    static func showHelp(anchor: String) {
        guard let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
        else { return }
        NSHelpManager.shared.openHelpAnchor(anchor, inBook: book)
    }

    /// The window's own way to Settings, besides the menu item and ⌘,.
    static func showSettings() {
        delegate?.showSettings(nil)
    }

    /// The menu bar a Mac app is expected to have (HIG, "The menu bar"):
    /// every command of the window is here too, with its shortcut.
    static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let app = submenu(of: menu, titled: "Mosaic")
        app.addItem(withTitle: "About Mosaic",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mosaic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Mosaic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: menu, titled: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // The album search field needs it to paste.
        let edit = submenu(of: menu, titled: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // As in Music: Play lives in Controls.
        let controls = submenu(of: menu, titled: "Controls")
        controls.addItem(withTitle: "Play", action: #selector(AppDelegate.play(_:)), keyEquivalent: "\r")
        controls.addItem(withTitle: "Update Photographs",
                         action: #selector(AppDelegate.updatePhotographs(_:)), keyEquivalent: "r")

        let window = submenu(of: menu, titled: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(of: menu, titled: "Help")
        help.addItem(withTitle: "Mosaic Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = help
        return menu
    }

    private static func submenu(of menu: NSMenu, titled title: String) -> NSMenu {
        let item = NSMenuItem()
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
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
    private var settingsWindow: NSWindow?
    private var model: AppModel?

    private var launchedAtLogin = false
    /// Off for the app's own restarts (`MosaicApplication.quitWithoutAsking`).
    var asksBeforeQuitting = true
    private static let quietQuitKey = "quitsWithoutWarning"
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
            // Sized by its content, which grows and shrinks with the steps.
            let controller = NSHostingController(rootView: AppView(model: model) { [weak self] in
                self?.play(nil)
            })
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Mosaic"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("Mosaic")
            window.center()
            self.window = window
        }
        Self.log.notice("window shown")
        model.windowOpened()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inviteToOpenAtLogin()
    }

    private var invitedToOpenAtLogin = false

    /// Once a launch, as the window opens: without opening at login, the
    /// screen saver's photographs fall behind the library unseen. A sheet,
    /// not a step: everything else may be done, and it can be declined.
    private func inviteToOpenAtLogin() {
        guard let model, let window, !invitedToOpenAtLogin, window.attachedSheet == nil else { return }
        model.refreshLoginItem()
        guard model.invitesToOpenAtLogin else { return }
        invitedToOpenAtLogin = true
        Self.log.notice("inviting to open at login")

        let alert = NSAlert()
        alert.messageText = "Open Mosaic at login?"
        alert.informativeText = "Mosaic keeps the screen saver’s photographs up to date only while it runs. At login it opens without a window and stays in the background."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { [weak self, weak alert] answer in
            guard let model = self?.model else { return }
            if answer == .alertFirstButtonReturn {
                model.setOpensAtLogin(true, reportingAt: .screenSaver)
            } else if alert?.suppressionButton?.state == .on {
                model.declineOpeningAtLogin()
            } else {
                Self.log.notice("opening at login put off until the next launch")
            }
        }
    }

    // MARK: Commands

    @objc func play(_ sender: Any?) {
        guard let model, model.canPlay else { return }
        do {
            try Player.play(preferences: model.preferences, on: window?.screen)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The mosaic could not start."
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc func updatePhotographs(_ sender: Any?) {
        model?.startIndexing()
    }

    /// One pane, so no toolbar; titled "Mosaic Settings", and neither
    /// minimised nor zoomed (HIG, "Settings").
    @objc func showSettings(_ sender: Any?) {
        guard let model else { return }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "Mosaic Settings"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Mosaic Settings")
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A login item that quits stops watching the library until the next
    /// login, and the screen saver's photographs fall behind it: say so, and
    /// offer what keeps them current — closing the window, the default.
    /// Not when the system quits the app to log out, restart or shut down,
    /// which it says in the quit event.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard asksBeforeQuitting, let model,
              !UserDefaults.standard.bool(forKey: Self.quietQuitKey)
        else { return .terminateNow }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEQuitApplication),
           event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        model.refreshLoginItem()
        guard model.opensAtLogin else { return .terminateNow }

        // Without a window there is nothing to close: Quit is the default.
        let windows = [window, settingsWindow].compactMap { $0 }.filter(\.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Mosaic?"
        alert.informativeText = "The screen saver won't pick up new photographs until you next log in."
        let close = windows.isEmpty ? nil : alert.addButton(withTitle: "Close Window")
        let quit = alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        let answer = alert.runModal()

        // Responses count the buttons from the first one added.
        let index = answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let chosen = alert.buttons.indices.contains(index) ? alert.buttons[index] : nil
        guard let chosen, chosen === close || chosen === quit else { return .terminateCancel }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.quietQuitKey)
        }
        if chosen === close {
            Self.log.notice("quit turned into closing the window")
            windows.forEach { $0.performClose(nil) }
            return .terminateCancel
        }
        Self.log.notice("quit by the user while a login item")
        return .terminateNow
    }

    /// A login item outlives its window, to keep watching the library; an app
    /// that is not one quits with it, as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let model else { return true }
        model.refreshLoginItem()
        return !model.opensAtLogin
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(play(_:)): model?.canPlay ?? false
        case #selector(updatePhotographs(_:)):
            model.map { !$0.isIndexing && $0.hasPhotographs } ?? false
        default: true
        }
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
