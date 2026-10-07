import Darwin
import Foundation

/// The quarantine attribute a download leaves on every file it unpacks.
///
/// A downloaded app carries it on every file inside it, and `copyItem` keeps
/// it. A quarantined copy of what the user has already let run is held by
/// Gatekeeper all over again: the saver behind a prompt raised from inside the
/// screen saver, where nobody sees it, and the app moved to Applications behind
/// a second "Open Anyway" (2026-10-07).
enum Quarantine {
    static func remove(from bundle: URL) throws {
        let attribute = "com.apple.quarantine"
        var paths = [bundle.path]
        if let contents = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in contents {
                paths.append(bundle.appendingPathComponent(relative).path)
            }
        }
        for path in paths where removexattr(path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }
}
