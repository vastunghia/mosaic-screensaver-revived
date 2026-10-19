import Foundation

/// Removes the thumbnails and close-ups that no generation of the index names
/// any more (evolution 2).
///
/// A build and a stocking of the shelf can do it themselves, and a folder's
/// harness lets them. The app does not: the saver reads a thumbnail and a
/// close-up at every cycle, from the generation it started with, so the files
/// of a subset just replaced stay until no saver runs, and those of the next
/// generation stay while it is being prepared. Called on the queue that
/// builds the index, never while a build runs: a file half written by one
/// is nobody's yet.
public enum IndexHousekeeping {
    public struct Report: Equatable, Sendable {
        public var thumbnails = 0
        public var closeUps = 0

        public init(thumbnails: Int = 0, closeUps: Int = 0) {
            self.thumbnails = thumbnails
            self.closeUps = closeUps
        }
    }

    /// Without a live manifest it removes nothing: an index that cannot be
    /// read names no file, and taking that literally would empty the
    /// directory and the shelf.
    @discardableResult
    public static func collect(index store: PhotoIndexStore, shelf: CloseUpShelf?) -> Report {
        let live = PhotoIndexStore(directory: store.directory)
        guard (try? live.load()) != nil else { return Report() }
        let entries = live.generations().flatMap(\.entries)
        var report = Report()
        report.thumbnails = (try? live.collectOrphans(keeping: Set(entries.map(\.thumbnail)))) ?? 0
        if let shelf {
            report.closeUps = shelf.collectOrphans(keeping: Set(entries.map(shelf.name(for:))))
        }
        return report
    }
}
