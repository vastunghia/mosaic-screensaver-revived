import CoreGraphics
import Foundation
import MosaicCore

/// What a source knows about one photograph before anything has been decoded.
public struct PhotoDescriptor: Equatable, Sendable {
    public let id: PhotoID

    /// Changes when the underlying image changes, so an index built from it can
    /// be invalidated without re-reading the pixels.
    public let versionToken: String

    /// When the photograph was taken, if the source knows. Only the choice of
    /// a subset reads it (SPEC § 5); nothing about a photograph's pixels does.
    public let creationDate: Date?

    public init(id: PhotoID, versionToken: String, creationDate: Date? = nil) {
        self.id = id
        self.versionToken = versionToken
        self.creationDate = creationDate
    }
}

/// Where images come from.
///
/// The point of this protocol is that nothing downstream of it can tell whether
/// the photographs live in the Photos library, in a folder, or nowhere at all.
/// PhotoKit implements it in `MosaicPhotoKit`, which only the app links and the
/// saver never does.
public protocol PhotoSource: Sendable {
    func photos() throws -> [PhotoDescriptor]

    /// The **canonical 16:9 crop** of `id`, at most `maxPixelWidth` across.
    ///
    /// The postcondition is the contract, and every source owes all of it:
    ///
    /// - the aspect ratio is `CanonicalAspect.ratio`, within one pixel;
    /// - the EXIF orientation has been applied, so the image is upright;
    /// - the colour space is sRGB, whatever the file said;
    /// - `maxPixelWidth` bounds the width **of the crop**, not the longest side
    ///   of the original. Sources may return something smaller when the original
    ///   is smaller; nothing may assume an exact size.
    ///
    /// SPEC § 4 gives every photograph one crop used at every scale, because it
    /// appears both as a tile and full screen and the two share an aspect ratio.
    /// Where the window sits is the index's to say (`FaceAwareCrop`, SPEC § 4):
    /// a source on its own knows no better than the centre, and an
    /// `IndexedPhotoSource` applies the window it stored.
    ///
    /// **This may block for hundreds of milliseconds** — it decodes a file. It
    /// must never be called from the render thread.
    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage

    /// The whole photograph, upright, at a size whose canonical crop is at most
    /// `cropWidth` across, in whatever colour space it came in.
    ///
    /// What the window is chosen on and then cut from: indexing looks for faces
    /// in this and crops these same pixels, so it decodes once. The default is
    /// right only for a source whose photographs are already 16:9.
    func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage
}

extension PhotoSource {
    public func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage {
        try canonicalImage(for: id, maxPixelWidth: cropWidth)
    }
}

public enum PhotoSourceError: Error, CustomStringConvertible {
    case unknownPhoto(PhotoID)
    case couldNotRender(PhotoID)
    case couldNotReadFolder(URL)

    /// The photograph exists but its pixels are not on this Mac, and fetching
    /// them was not allowed — an iCloud photograph with downloads turned off
    /// (SPEC § 5), or here only as a derivative smaller than was asked for.
    /// Not a failure of the photograph: it is worth asking again
    /// once downloads are allowed, so an index must not remember it as broken.
    case unavailable(PhotoID)

    public var description: String {
        switch self {
        case .unknownPhoto(let id): return "no photograph called \(id.rawValue)"
        case .couldNotRender(let id): return "could not render \(id.rawValue)"
        case .couldNotReadFolder(let url): return "could not read the folder \(url.path)"
        case .unavailable(let id): return "\(id.rawValue) is not on this Mac"
        }
    }
}
