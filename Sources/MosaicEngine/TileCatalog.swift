import Foundation
import MosaicCore

/// The colours a planner reasons about, and where a target's grid comes from.
///
/// It exists so that `SolvedMosaicPlanner` can be exercised against a synthetic
/// catalogue with no disk in the loop, and so that `MosaicSolver` stays a pure
/// function of numbers with no idea that photographs are files.
public protocol TileCatalog: Sendable {
    var photos: [PhotoID] { get }

    /// The stored signature, or nil if this catalogue has nothing for it.
    func signature(for photo: PhotoID) -> TileSignature?

    /// The photograph sampled on a mosaic's own grid — SPEC § 5 step 2.
    ///
    /// **It must come from the same pixels in every host.** The app has the
    /// originals and the .saver does not, so a target sampled from originals in
    /// one and from thumbnails in the other would give two different mosaics from
    /// the same index and the same seed. Originals supply pixels, never choices.
    func targetGrid(for photo: PhotoID, rows: Int, detail: Int) throws -> TargetGrid

    /// Whether the photograph has the pixels to be a subject — and so, a cycle
    /// later, the anchor that fills the screen — or is a tile only (SPEC § 5,
    /// the two roles).
    func canFillScreen(_ photo: PhotoID) -> Bool

    /// How many pixels across the catalogue has the photograph, if it knows:
    /// nil is as many as anything asks for.
    func pixelWidth(of photo: PhotoID) -> Int?
}

extension TileCatalog {
    public func canFillScreen(_ photo: PhotoID) -> Bool { true }
    public func pixelWidth(of photo: PhotoID) -> Int? { nil }
}
