// The index format and the utilities shared between the app side (which writes it) and the
// saver side (which reads it back). It is deliberately poor: the point of the spike is not
// to design the format of M5, but to show that the chain holds across the sandbox boundary.

import Foundation
import os

let log3 = OSLog(subsystem: "dev.mosaic.spike3", category: "photokit")

func say(_ message: String) {
    os_log("%{public}@", log: log3, type: .default, message)   // literal `type:`, see spike 1
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

/// The real home: from inside the saver, `NSHomeDirectory()` is the container.
func realHomeDirectory() -> String {
    let h = NSHomeDirectory()
    if let r = h.range(of: "/Library/Containers/") { return String(h[h.startIndex..<r.lowerBound]) }
    return h
}

/// The app's own home, where spike 2 showed the saver can read.
var indexDirectory: String { realHomeDirectory() + "/Library/Application Support/MosaicSpike3" }
var indexFile: String { indexDirectory + "/index.json" }
var thumbsDirectory: String { indexDirectory + "/thumbs" }

struct Entry: Codable {
    let id: String          // PHAsset.localIdentifier
    let file: String        // name of the JPEG in thumbs/
    let r: Double           // average colour, sRGB 0-1
    let g: Double
    let b: Double
    let width: Int          // original dimensions of the asset
    let height: Int
}

struct Index: Codable {
    let created: Date
    let libraryTotal: Int
    let entries: [Entry]
}
