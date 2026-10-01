// Spike 4 — the app side: a probe that says who launched it and what it can read.
//
// It stands in for Mosaic.app. It has an identity of its own, so the Photos grant
// it is given is its own, the way Mosaic's would be. Every launch writes one block
// to the unified log and quits:
//
//   /usr/bin/log show --last 1h --predicate 'subsystem == "dev.mosaic.spike4"' --style compact
//
// Flags:
//   --request     ask for Photos access (run once by hand, with `open`)
//   --register    register itself as a login item (SMAppService.mainApp)
//   --unregister  remove it
//   anything else is only logged, so a launcher can say who it is

import AppKit
import Darwin
import os
import Photos
import ServiceManagement

private let log = OSLog(subsystem: "dev.mosaic.spike4", category: "probe")

private func say(_ message: String) {
    os_log("%{public}@", log: log, type: .default, message)
    print("PROBE: " + message)
}

/// The executable of a process, from its pid.
private func path(of pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : "(pid \(pid), unreadable)"
}

private func describe(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorized: "authorized"
    case .limited: "limited"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

private func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
}

/// What macOS says about the launch: the `oapp` event's property, which is
/// `lgit` for a login item (the classic way of telling).
private func launchContext() -> String {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else {
        return "no launch event"
    }
    let property = event.paramDescriptor(forKeyword: keyAEPropData)
    let code = property.map { descriptor -> String in
        let value = descriptor.enumCodeValue
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
    let isLoginItem = property?.enumCodeValue == keyAELaunchedAsLogInItem
    return "event \(event.eventClass.fourCC)/\(event.eventID.fourCC), property \(code ?? "none"), login item \(isLoginItem)"
}

extension UInt32 {
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
    }
}

/// Reads one image for real: a status that says "authorized" is not the same
/// as pixels arriving.
private func readOnePhoto() -> String {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: options)
    guard let first = assets.firstObject else { return "\(assets.count) images, none to read" }
    let request = PHImageRequestOptions()
    request.isSynchronous = true
    request.deliveryMode = .highQualityFormat
    request.isNetworkAccessAllowed = false
    var size = "nothing"
    PHImageManager.default().requestImage(
        for: first, targetSize: CGSize(width: 256, height: 256),
        contentMode: .aspectFit, options: request
    ) { image, info in
        if let image { size = "\(Int(image.size.width))×\(Int(image.size.height))" }
        if let error = info?[PHImageErrorKey] { size += " error \(error)" }
    }
    return "\(assets.count) images, first read as \(size)"
}

final class Delegate: NSObject, NSApplicationDelegate {
    /// The launch event is only current while the app is finishing launching.
    private var context = "not read"

    func applicationWillFinishLaunching(_ notification: Notification) {
        context = launchContext()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openApplication(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication)
        )
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        say("open-URL event: \(event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? "no URL")")
    }

    @objc func openApplication(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        say("open-application event: \(launchContext())")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let parent = getppid()
        say("""
            launched pid \(getpid()), parent \(parent) \(path(of: parent)), \
            arguments \(arguments), \(context), \
            default launch \(notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] ?? "absent")
            """)

        let service = SMAppService.mainApp
        if arguments.contains("--register") {
            do { try service.register(); say("login item registered") }
            catch { say("login item registration failed: \(error)") }
        }
        if arguments.contains("--unregister") {
            do { try service.unregister(); say("login item unregistered") }
            catch { say("login item unregistration failed: \(error)") }
        }
        say("login item status \(describe(service.status))")

        if arguments.contains("--request") {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                say("Photos access asked: \(describe(status))")
                DispatchQueue.main.async { self.finish() }
            }
            return
        }
        finish()
    }

    private func finish() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        say("Photos access \(describe(status))")
        if status == .authorized || status == .limited {
            say(readOnePhoto())
        }
        say("done")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
