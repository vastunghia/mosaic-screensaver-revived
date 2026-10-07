import Foundation
import Photos

/// Tells its owner that the library changed, at most once per `quiet` seconds.
///
/// PhotoKit reports changes in bursts — an import is hundreds of them, and the
/// library's own background analysis touches photographs all day — so each one
/// restarts a short wait, and the handler runs once the library has been quiet
/// for that long. The handler starts an incremental build, which reads only
/// what changed.
///
/// Registering before the user has granted access would make PhotoKit ask, so
/// the owner creates this only once access is settled.
///
/// Registering waits for the library to open, which at login took 69 s: it
/// happens on the observer's own queue, never on the caller's thread.
public final class PhotoLibraryChanges: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let quiet: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "mosaic.photos.changes")
    private var pending: DispatchWorkItem?

    public init(quiet: TimeInterval = 10, handler: @escaping @Sendable () -> Void) {
        self.quiet = quiet
        self.handler = handler
        super.init()
        queue.async { [self] in PHPhotoLibrary.shared().register(self) }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        queue.async { [self] in
            pending?.cancel()
            let work = DispatchWorkItem { [handler] in handler() }
            pending = work
            queue.asyncAfter(deadline: .now() + quiet, execute: work)
        }
    }
}
