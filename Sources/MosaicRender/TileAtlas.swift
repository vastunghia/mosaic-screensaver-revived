import Metal
import MosaicCore

/// The tiles, as the renderer sees them: one texture array, one slice per
/// photograph, with a mip pyramid.
///
/// Only the contract lives here. Building and keeping the textures is M6's
/// business, in TileStore, and the renderer never learns how it is done.
public protocol TileSliceMap {
    /// Where a photograph sits in the texture array, or nil if the atlas does
    /// not hold it.
    func slice(for photo: PhotoID) -> Int?
}

public protocol TileAtlas: AnyObject, TileSliceMap {
    var texture: MTLTexture { get }
}
