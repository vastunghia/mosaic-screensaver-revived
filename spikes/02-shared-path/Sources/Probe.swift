// Probes shared between the app side and the saver side of spike 2.
//
// Both sides try the same paths and write the outcome to the unified log, which is the only
// channel readable from inside legacyScreenSaver. The comparison between the two columns of
// results is the deliverable of the spike.

import Foundation
import os

let spike2Log = OSLog(subsystem: "dev.mosaic.spike2", category: "paths")

func say(_ message: String) {
    // `type:` must be a literal, see spike 1.
    os_log("%{public}@", log: spike2Log, type: .default, message)
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// The container shared by every third-party .saver, discovered in spike 1.
let legacyContainer = "/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

/// The candidates for the index the app has to write and the saver to read back.
/// `home` differs between the two sides: for the app it is the real home, for the saver it
/// is the container.
func candidates(realHome: String) -> [(name: String, dir: String)] {
    [
        ("container-appsupport", realHome + legacyContainer + "/Library/Application Support/MosaicSpike2"),
        ("container-byhost",     realHome + legacyContainer + "/Library/Preferences/ByHost"),
        ("home-appsupport",      realHome + "/Library/Application Support/MosaicSpike2"),
        ("users-shared",         "/Users/Shared/MosaicSpike2"),
        ("home-pictures",        realHome + "/Pictures/MosaicSpike2"),
    ]
}

/// The user's real home, even from inside the sandbox where NSHomeDirectory() is the container.
func realHomeDirectory() -> String {
    let h = NSHomeDirectory()
    if let r = h.range(of: "/Library/Containers/") {
        return String(h[h.startIndex..<r.lowerBound])
    }
    return h
}

enum Outcome: String {
    case ok = "ok"
    case denied = "DENIED"
    case missing = "missing"
}

/// Tries to create the directory and write a file into it. Returns the outcome and the raw error.
func tryWrite(dir: String, fileName: String, content: String) -> (Outcome, String) {
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        return (.denied, "mkdir: \(errorDescription(error))")
    }
    do {
        try content.write(toFile: dir + "/" + fileName, atomically: true, encoding: .utf8)
        return (.ok, "")
    } catch {
        return (.denied, "write: \(errorDescription(error))")
    }
}

/// Tries to read a file. `missing` tells "it is not there" apart from "I am not allowed".
func tryRead(dir: String, fileName: String) -> (Outcome, String) {
    let path = dir + "/" + fileName
    if !FileManager.default.fileExists(atPath: path) {
        // Careful: inside the sandbox fileExists can say false even when the file is there
        // but the path is forbidden. We try to open it anyway, to tell the cases apart.
        do {
            let s = try String(contentsOfFile: path, encoding: .utf8)
            return (.ok, s.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            let e = errorDescription(error)
            return (e.contains("NSCocoaErrorDomain Code=260") || e.contains("No such file") ? .missing : .denied, e)
        }
    }
    do {
        let s = try String(contentsOfFile: path, encoding: .utf8)
        return (.ok, s.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        return (.denied, errorDescription(error))
    }
}

func errorDescription(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) Code=\(ns.code) \(ns.localizedDescription)"
}

func line(_ role: String, _ name: String, _ action: String, _ outcome: Outcome, _ detail: String) -> String {
    let d = detail.isEmpty ? "" : "  <\(detail)>"
    return "SPIKE2 \(role.padding(toLength: 6, withPad: " ", startingAt: 0)) "
         + "\(name.padding(toLength: 22, withPad: " ", startingAt: 0)) "
         + "\(action.padding(toLength: 9, withPad: " ", startingAt: 0)) "
         + "\(outcome.rawValue)\(d)"
}
