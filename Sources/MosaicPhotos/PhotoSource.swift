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

    /// An image for `id`, at most `maxPixelWidth` across. Sources are free to
    /// return something smaller; nothing may assume an exact size.
    func image(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage
}

public enum PhotoSourceError: Error {
    case unknownPhoto(PhotoID)
    case couldNotRender(PhotoID)
}
