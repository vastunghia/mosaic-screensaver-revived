import Foundation
import MosaicCore

/// Subjects that come round again — A, B, C, A, B, C… — each time as the very
/// same mosaic, so that a run of `ring.count` cycles ends on the frame it began
/// with and plays as an endless loop (the README's video).
///
/// Every cycle starts on the mosaic of the subject before at rest, full screen
/// (SPEC § 2), and that mosaic depends on its subject, on the subject before it
/// (the anchor, SPEC § 5) and on the seed of its solve. The engine derives the
/// seed from the cycle's number; here it comes from the subject's place in the
/// ring instead, so cycle n and cycle n + ring.count are one solve. Cycle 0 has
/// no subject before it, so a loop is taken from cycle `ring.count` on.
public struct LoopingPlanner: MosaicPlanner {
    public let inner: any MosaicPlanner
    public let ring: [PhotoID]
    public let seed: UInt64

    /// - Precondition: at least two photographs, all different: a subject
    ///   inside its own mosaic would zoom out to itself.
    public init(inner: any MosaicPlanner, ring: [PhotoID], seed: UInt64) {
        precondition(ring.count >= 2 && Set(ring).count == ring.count, "a loop needs two or more different subjects")
        self.inner = inner
        self.ring = ring
        self.seed = seed
    }

    public func subject(ofCycle index: Int) -> PhotoID {
        ring[((index % ring.count) + ring.count) % ring.count]
    }

    public func plan(
        rows: Int,
        subject: PhotoID,
        previousSubject: PhotoID?,
        seed cycleSeed: UInt64
    ) throws -> PlannedMosaic {
        guard let place = ring.firstIndex(of: subject) else {
            return try inner.plan(rows: rows, subject: subject, previousSubject: previousSubject, seed: cycleSeed)
        }
        return try inner.plan(
            rows: rows, subject: subject, previousSubject: previousSubject,
            seed: seed &+ UInt64(place + 1) &* 0x9E37_79B9_7F4A_7C15
        )
    }
}
