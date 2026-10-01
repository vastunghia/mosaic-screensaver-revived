// Spike 4 — the saver side: can a .saver, inside legacyScreenSaver, launch an app?
//
// Which way it tries is read from /Users/Shared/mosaic-spike4/method (the saver
// can read there, spike 2), so the same build tries each in turn without going
// back to System Settings. No file, no attempt: the preview in System Settings
// stays quiet while the saver is being chosen.
//
//   workspace   NSWorkspace.openApplication(at:configuration:), not activating
//   open-url    NSWorkspace.open(_:) on the app's bundle
//   exec        Process on the app's executable
//   open-tool   Process on /usr/bin/open -b <bundle id>
//   url-scheme  NSWorkspace.open(_:) on a spike4probe:// URL, which carries data
//
//   /usr/bin/log show --last 1h --predicate 'subsystem == "dev.mosaic.spike4"' --style compact

import AppKit
import ScreenSaver
import os

private let log = OSLog(subsystem: "dev.mosaic.spike4", category: "saver")

private func say(_ message: String) {
    os_log("%{public}@", log: log, type: .default, message)
    FileHandle.standardError.write(("SAVER: " + message + "\n").data(using: .utf8)!)
}

private let probeID = "dev.mosaic.spike4.probe"
private let methodFile = "/Users/Shared/mosaic-spike4/method"

/// Once per method: the preview and the full-screen saver are separate
/// instances, and legacyScreenSaver outlives a run of the saver.
private var attempted: String?

@objc(LauncherView)
final class LauncherView: ScreenSaverView {
    private var status = "idle"

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 2
        let p = ProcessInfo.processInfo
        say("start — process \(p.processName) pid \(p.processIdentifier) preview \(isPreview) home \(NSHomeDirectory())")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func startAnimation() {
        super.startAnimation()
        guard let method = try? String(contentsOfFile: methodFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !method.isEmpty, method != attempted
        else {
            say("no new method in \(methodFile): not launching")
            return
        }
        attempted = method
        launch(method)
    }

    private func launch(_ method: String) {
        let workspace = NSWorkspace.shared
        let found = workspace.urlForApplication(withBundleIdentifier: probeID)
        say("method \(method) · preview \(isPreview) · LaunchServices finds the probe at \(found?.path ?? "nil")")
        guard let url = found else {
            status = "\(method): probe not found"
            return
        }
        let marker = "--from-saver-\(method)"

        switch method {
        case "workspace":
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = [marker]
            workspace.openApplication(at: url, configuration: configuration) { app, error in
                say("workspace: app \(app.map { "pid \($0.processIdentifier)" } ?? "nil"), error \(error.map { "\($0)" } ?? "none")")
            }
        case "open-url":
            let opened = workspace.open(url)
            say("open-url: returned \(opened)")
        case "exec":
            run(url.appendingPathComponent("Contents/MacOS/Spike4Probe").path, [marker])
        case "url-scheme":
            let opened = workspace.open(URL(string: "spike4probe://from-saver?reason=index-missing")!)
            say("url-scheme: returned \(opened)")
        case "open-tool":
            run("/usr/bin/open", ["-g", "-b", probeID, "--args", marker])
        default:
            say("unknown method \(method)")
        }
        status = "\(method): tried"

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: probeID)
            say("\(method): 4 s later the probe is running \(running.count) time(s), \(running.map { "pid \($0.processIdentifier)" })")
        }
    }

    private func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            say("\(executable): started pid \(process.processIdentifier)")
            DispatchQueue.global().async {
                process.waitUntilExit()
                say("\(executable): exited \(process.terminationStatus), reason \(process.terminationReason.rawValue)")
            }
        } catch {
            say("\(executable): failed to start: \(error)")
        }
    }

    override func animateOneFrame() {
        setNeedsDisplay(bounds)
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("Spike 4 — \(status)" as NSString).draw(
            in: bounds.insetBy(dx: 20, dy: bounds.height / 2 - 30),
            withAttributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedSystemFont(ofSize: isPreview ? 7 : 24, weight: .regular),
                .paragraphStyle: style,
            ]
        )
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
