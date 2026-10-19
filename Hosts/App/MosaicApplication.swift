import AppKit
import AppUpdate
import Combine
import PhotoIndex
import SharedStore
import SwiftUI
import UserNotifications
import os

/// M9 as a user sees it: launched with no flags — from the Finder, or with a
/// bare `open "Mosaic Companion.app"` — the app opens its own window instead of the
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

    /// The window's own way to the update it shows as available.
    static func offerUpdate() {
        delegate?.offerUpdate()
    }

    /// The menu bar a Mac app is expected to have (HIG, "The menu bar"):
    /// every command of the window is here too, with its shortcut.
    static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let app = submenu(of: menu, titled: "Mosaic Companion")
        app.addItem(withTitle: "About Mosaic Companion",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Set Up Mosaic…", action: #selector(AppDelegate.showSetup(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mosaic Companion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Mosaic Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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

        // Controls, as in Music; "Enter Full Screen", as everywhere, since
        // the mosaic already runs in the window.
        let controls = submenu(of: menu, titled: "Controls")
        controls.addItem(withTitle: "Enter Full Screen", action: #selector(AppDelegate.play(_:)), keyEquivalent: "\r")
        controls.addItem(withTitle: "Update Photographs",
                         action: #selector(AppDelegate.updatePhotographs(_:)), keyEquivalent: "r")

        let window = submenu(of: menu, titled: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(of: menu, titled: "Help")
        help.addItem(withTitle: "Mosaic Companion Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
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
    private var setupWindow: NSWindow?
    /// Closed halfway this launch: the window opens instead, and the setup
    /// waits for the next launch or the menu.
    private var setupPutOff = false
    private var model: AppModel?
    private let updater = Updater()
    private var updateWatch: AnyCancellable?

    private var launchedAtLogin = false
    /// Off for the app's own restarts (`MosaicApplication.quitWithoutAsking`).
    var asksBeforeQuitting = true
    private static let quietQuitKey = "quitsWithoutWarning"
    /// Set by NSWorkspace before the system quits the apps to log out,
    /// restart or shut down; cleared after a while, in case another app
    /// cancels it.
    private var systemIsPoweringOff = false
    private var powerOffReset: Task<Void, Never>?
    /// URLs that arrive before the model exists, during launch.
    private var earlyCalls: [MosaicURL] = []

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch ends, so that a click that launched the app arrives.
        UNUserNotificationCenter.current().delegate = self
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )
    }

    @objc private func systemWillPowerOff(_ notification: Notification) {
        Self.log.notice("the system is logging out, restarting or shutting down")
        systemIsPoweringOff = true
        powerOffReset?.cancel()
        powerOffReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.systemIsPoweringOff = false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wantsWindow = !launchedAtLogin && (earlyCalls.isEmpty || earlyCalls.contains(.open))
        let launch = launchedAtLogin ? "at login" : earlyCalls.isEmpty ? "by hand"
            : earlyCalls.map { "\($0.url)" }.joined(separator: ", ")
        Self.log.notice("launched \(launch, privacy: .public), \(wantsWindow ? "with" : "without", privacy: .public) a window")

        let model = AppModel(foreground: wantsWindow)
        self.model = model
        model.finishUpdate()
        if wantsWindow { showWindow() }
        // An update prepared in the background is offered as soon as there is
        // a window to offer it in.
        // Without a window — the login item nobody looks at — a notification.
        updateWatch = updater.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, case .ready(let release, _) = state else { return }
            if window?.isVisible == true {
                showNextSheet()
            } else {
                UpdateNotice.post(release)
            }
        }

        updater.start()
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
        case .update(let reason): model?.updateRequested(reason: reason, bySaver: true)
        }
    }

    /// Double-clicked in the Finder while running without a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    private func showWindow() {
        guard let model else { return }
        if SetupAssistant.isDue, !setupPutOff {
            showSetup(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            NSApp.mainMenu = MosaicApplication.mainMenu()
            // Sized by its content, which grows and shrinks with its status.
            let controller = NSHostingController(rootView: AppView(model: model, updater: updater) { [weak self] in
                self?.play(nil)
            })
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Mosaic Companion"
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
        showNextSheet()
    }

    // MARK: Sheets on the window

    private var offeredUpdate: ReleaseVersion?

    /// One sheet at a time, at most once a launch: an update ready to
    /// install. Called again as a sheet ends.
    private func showNextSheet() {
        guard let window, window.isVisible else { return }
        // Called from a sheet's completion handler, the sheet is still
        // attached until this turn of the run loop ends.
        guard window.attachedSheet == nil else {
            DispatchQueue.main.async { [weak self] in
                guard self?.window?.attachedSheet == nil else { return }
                self?.showNextSheet()
            }
            return
        }
        if let release = updater.readyRelease, offeredUpdate != release.version {
            offerUpdate()
        }
    }

    // MARK: Setup

    /// The setup, in a window of its own: by itself at the first launch and
    /// after an update that changes it (`SetupAssistant`), or from the menu.
    /// The main window opens when it ends, finished or closed.
    @objc func showSetup(_ sender: Any?) {
        guard let model else { return }
        NSApp.setActivationPolicy(.regular)
        if window == nil { NSApp.mainMenu = MosaicApplication.mainMenu() }
        if setupWindow == nil {
            let controller = NSHostingController(rootView: SetupView(model: model) { [weak self] in
                self?.finishSetup()
            })
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "Set Up Mosaic"
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Its size before centring it: the view sets it only once laid out.
            window.setContentSize(controller.view.fittingSize)
            window.center()
            setupWindow = window
        }
        Self.log.notice("setup shown")
        model.windowOpened()
        window?.orderOut(nil)
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishSetup() {
        SetupAssistant.finish()
        Self.log.notice("setup finished, revision \(SetupAssistant.revision, privacy: .public)")
        let setup = setupWindow
        setupWindow = nil
        setup?.delegate = nil
        setup?.close()
        showWindow()
    }

    /// The prepared update, with its notes: install and relaunch, later, or
    /// never for this version.
    func offerUpdate() {
        guard let window, let release = updater.readyRelease, let current = updater.current else { return }
        guard window.attachedSheet == nil else { return }
        offeredUpdate = release.version
        UpdateNotice.withdraw()

        let alert = NSAlert()
        alert.messageText = "Mosaic \(release.version) is available"
        var text = "You have \(current). Mosaic Companion will relaunch in the new version and update the screen saver too."
        if updater.needsAdministrator {
            text += " Replacing it in Applications needs an administrator’s name and password."
        }
        alert.informativeText = text
        if let notes = Self.notesView(release.notes) { alert.accessoryView = notes }
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Skip This Version")
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .alertFirstButtonReturn:
                Task {
                    do {
                        try await self.updater.install()
                    } catch {
                        self.show(error: error, about: "Mosaic \(release.version) could not be installed.")
                    }
                }
            case .alertThirdButtonReturn:
                updater.skip()
            default:
                Self.log.notice("update put off")
            }
        }
    }

    /// The release notes, as on the release page, in a box that scrolls.
    private static func notesView(_ notes: String) -> NSView? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: trimmed, options: options)) ?? AttributedString(trimmed)
        let text = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: text.length)
        let size = NSFont.smallSystemFontSize
        // Markdown marks bold with an inline intent, which AppKit does not draw.
        text.addAttributes([.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor], range: whole)
        parsed.runs.forEach { run in
            guard let intent = run.inlinePresentationIntent else { return }
            let range = NSRange(run.range, in: parsed)
            if intent.contains(.stronglyEmphasized) {
                text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
            }
            if intent.contains(.code) {
                text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: range)
            }
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 4, height: 4)
            view.textStorage?.setAttributedString(text)
        }
        return scroll
    }

    private func show(error: Error, about message: String) {
        let alert = NSAlert()
        alert.messageText = message
        let reason = error.localizedDescription
        alert.informativeText = reason.prefix(1).uppercased() + String(reason.dropFirst()) + "."
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    /// Check for Updates…: says what it found, even "nothing", and offers a
    /// version the user once skipped.
    @objc func checkForUpdates(_ sender: Any?) {
        showWindow()
        Task {
            switch await updater.check(byUser: true) {
            case .available:
                offeredUpdate = nil
                offerUpdate()
            case .upToDate(let version):
                let alert = NSAlert()
                alert.messageText = "Mosaic is up to date"
                alert.informativeText = "Mosaic \(version) is the newest version."
                if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            case .failed(let reason):
                show(error: UpdateCheckFailure(reason: reason), about: "Mosaic couldn’t check for updates.")
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

    /// One pane, so no toolbar; titled "Mosaic Companion Settings", and neither
    /// minimised nor zoomed (HIG, "Settings").
    @objc func showSettings(_ sender: Any?) {
        guard let model else { return }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.title = "Mosaic Companion Settings"
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
    /// Not when the system quits the app to log out, restart or shut down:
    /// NSWorkspace says so first, and the quit event carries a reason —
    /// as an attribute, although AERegistry.h calls it a parameter.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard asksBeforeQuitting, let model,
              !UserDefaults.standard.bool(forKey: Self.quietQuitKey)
        else { return .terminateNow }
        if systemIsPoweringOff {
            Self.log.notice("quit by the system")
            return .terminateNow
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEQuitApplication) {
            let reason = AEKeyword(kAEQuitReason)
            if event.attributeDescriptor(forKeyword: reason) != nil
                || event.paramDescriptor(forKeyword: reason) != nil {
                Self.log.notice("quit by the system, with a reason in the quit event")
                return .terminateNow
            }
        }
        model.refreshLoginItem()
        guard model.opensAtLogin else { return .terminateNow }

        // Without a window there is nothing to close: Quit is the default.
        let windows = [window, settingsWindow, setupWindow].compactMap { $0 }.filter(\.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Mosaic Companion?"
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
        case #selector(checkForUpdates(_:)): updater.isAvailable && !updater.isBusy
        default: true
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        // The setup closed before its end: put off, and the window opens.
        if let closing = notification.object as? NSWindow, closing === setupWindow {
            setupWindow = nil
            setupPutOff = true
            Self.log.notice("setup closed before its end: put off until the next launch")
            // Now, not later: with no window left, an app that is not a
            // login item would quit.
            showWindow()
            return
        }
        model.refreshLoginItem()
        if model.opensAtLogin {
            model.windowClosed()
            Self.log.notice("window closed; staying in the background as a login item")
            // Back out of the Dock, after the window has gone.
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

private struct UpdateCheckFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// The update notification, clicked: the window, with the update in it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == UpdateNotice.identifier else { return }
        await MainActor.run {
            Self.log.notice("update notification clicked")
            showWindow()
            offerUpdate()
        }
    }

    /// With the window in front the sheet says it already.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { window?.isVisible == true ? [] : [.banner, .list] }
    }
}
