import Foundation

/// M11: where the app leaves things for the .saver.
///
/// Spike 2 settled the contract: the app writes into its own Application
/// Support directory, and the saver, whose sandbox lets it read outside its
/// container but not write, reads from there. Nothing here is a channel
/// between processes — only paths both sides agree on, kept in one place so
/// that if a future macOS changes the sandbox rules, this is the module that
/// changes.
public enum SharedLocations {
    /// `~/Library/Application Support/Mosaic`, for the real user.
    ///
    /// Inside `legacyScreenSaver` the home directory Foundation reports is the
    /// sandbox container (`~/Library/Containers/com.apple.ScreenSaver.Engine.
    /// legacyScreenSaver/Data`), and so is the Application Support it finds.
    /// The password database is not redirected, so the app and the saver
    /// resolve the same directory.
    public static var supportDirectory: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The photo index: manifest and thumbnails.
    public static var indexDirectory: URL {
        supportDirectory.appendingPathComponent("index", isDirectory: true)
    }

    /// Close-ups at the anchor's width, made by the app from the originals,
    /// which the saver cannot reach.
    public static var closeUpDirectory: URL {
        supportDirectory.appendingPathComponent("closeups", isDirectory: true)
    }

    /// The directory name is part of the contract, like the bundle identifiers
    /// in `scripts/identity.sh`: renaming it orphans every index already built.
    public static let directoryName = "Mosaic"

    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        // Not expected; and outside a sandbox this is the same directory.
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
