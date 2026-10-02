import CoreGraphics
import Foundation
import Vision

/// Faces in a photograph, found by Vision, for placing its crop (SPEC § 4).
///
/// Here and not in `MosaicPhotos` because only indexing looks for faces: the
/// window is chosen once and written into the index, and everything after —
/// the saver included — reads it rather than looking again. The faces are
/// *detected*, not the people Photos *recognised*: public PhotoKit does not
/// expose those (verified 2026-10-01).
public enum FaceDetector {
    public struct Face: Equatable, Sendable {
        /// In the pixels of the image searched, origin at the top left.
        public let rect: CGRect
        public let confidence: Float
    }

    /// Pinned, not the default: a newer revision finds different faces, which
    /// would move windows under an index that believes itself current. The
    /// `faces` specimen of 2026-10-02 was judged on this one. Changing it is
    /// changing `CropRule`.
    public static let revision = VNDetectFaceRectanglesRequestRevision3

    public static func faces(in image: CGImage) throws -> [Face] {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = revision
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let width = Double(image.width)
        let height = Double(image.height)
        return (request.results ?? []).map { observation in
            // Vision is normalised with the origin at the bottom left.
            let box = observation.boundingBox
            return Face(
                rect: CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                ),
                confidence: observation.confidence
            )
        }
    }
}
