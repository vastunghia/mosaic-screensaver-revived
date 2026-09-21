import CoreGraphics
import Foundation
import MosaicCore

/// What a source knows about one photograph before anything has been decoded.
public struct PhotoDescriptor: Equatable, Sendable {
    public let id: PhotoID

    /// Changes when the underlying image changes, so an index built from it can
    /// be invalidated without re-reading the pixels.
    public let versionToken: String

    public init(id: PhotoID, versionToken: String) {
        self.id = id
        self.versionToken = versionToken
    }
}

/// Where images come from.
///
/// The point of this protocol is that nothing downstream of it can tell whether
/// the photographs live in the Photos library, in a folder, or nowhere at all.
/// PhotoKit will implement it one day, in the app and never in the saver.
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
    /// Vertical photographs are centre cropped (§ 8.2, closed).
    ///
    /// **This may block for hundreds of milliseconds** — it decodes a file. It
    /// must never be called from the render thread.
    func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage
}

public enum PhotoSourceError: Error, CustomStringConvertible {
    case unknownPhoto(PhotoID)
    case couldNotRender(PhotoID)
    case couldNotReadFolder(URL)

    public var description: String {
        switch self {
        case .unknownPhoto(let id): return "no photograph called \(id.rawValue)"
        case .couldNotRender(let id): return "could not render \(id.rawValue)"
        case .couldNotReadFolder(let url): return "could not read the folder \(url.path)"
        }
    }
}
