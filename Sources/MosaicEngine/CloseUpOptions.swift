import Foundation

/// Which tiles get close-ups, and how many pixels across.
///
/// Settled by looking at specimens of the start of a cycle at 4096 pixels
/// (PLAN.md, M6):
///
/// - **the anchor at 1920**, because 2560 and screen width could hardly be told
///   apart from it, and the .saver will need one stored rendition of that size
///   for every photograph in the pool;
/// - **a ring of 3** around it, because the cells three away are still three
///   to four atlas slices wide when they come on screen;
/// - **the ring at 640**, the index's thumbnail width: the originals were
///   judged more than the ring needs, and the thumbnails make it identical in
///   the app and the .saver at no cost on disk.
public struct CloseUpOptions: Equatable, Sendable {
    /// How far from the anchor, in cells. 0 is the anchor alone.
    public var ring: Int

    /// The most pixels across a close-up of the anchor may have; nil is as wide
    /// as it gets on screen.
    public var anchorWidth: Int?

    /// The same for the ring.
    public var ringWidth: Int?

    public init(ring: Int, anchorWidth: Int?, ringWidth: Int?) {
        self.ring = max(0, ring)
        self.anchorWidth = anchorWidth
        self.ringWidth = ringWidth
    }

    public static let standard = CloseUpOptions(ring: 3, anchorWidth: 1920, ringWidth: 640)
}
