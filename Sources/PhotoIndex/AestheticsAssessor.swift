import CoreGraphics
import Foundation
import Vision

/// Vision's verdict on a photograph's looks, for leaving the weak ones and the
/// utility shots out of the index (spike 5).
///
/// Here, beside `FaceDetector`, for the same reason: only indexing asks, once,
/// and writes the answer down. The synchronous `VN` request and not the async
/// `CalculateImageAestheticsScoresRequest` the spike used, because indexing
/// runs inside `concurrentPerform`.
public enum AestheticsAssessor {
    public struct Scores: Equatable, Sendable {
        /// From −1, least desirable, to 1. Not Photos' scale: see spike 5,
        /// «Mapping Vision onto Photos' scale».
        public let overall: Float
        /// Not necessarily a poor photograph, but a receipt, a meter, a
        /// document: something nobody wants on screen.
        public let isUtility: Bool

        public init(overall: Float, isUtility: Bool) {
            self.overall = overall
            self.isUtility = isUtility
        }
    }

    /// Pinned, as `FaceDetector.revision` is: a newer model scores differently,
    /// and the map onto Photos' scale was fitted on this one.
    public static let revision = VNCalculateImageAestheticsScoresRequestRevision1

    public static func scores(of image: CGImage) throws -> Scores? {
        let request = VNCalculateImageAestheticsScoresRequest()
        request.revision = revision
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results?.first.map { Scores(overall: $0.overallScore, isUtility: $0.isUtility) }
    }
}

/// What indexing asks of a photograph's looks once it has decoded it: the
/// contract `PhotoIndexBuilder` holds Vision to, and a fake in the tests,
/// where Vision on every core at once hangs the process (as with faces).
public protocol PhotoAssessing: Sendable {
    /// Changes whenever a verdict would: the model, its revision, the sizes
    /// looked at. An assessment made under another is made again.
    var revision: String { get }

    /// `image` is the whole photograph, upright, as indexing decoded it.
    /// `small` gives it at most that many pixels on its long side, scaled
    /// as the source scales, or nil. The score is wanted only for a
    /// photograph Photos has not scored.
    func assess(_ image: CGImage, small: (Int) -> CGImage?, wantsScore: Bool) throws -> AestheticVerdict
}

public struct AestheticVerdict: Equatable, Sendable {
    public var utility: Bool
    public var smallUtility: Bool?
    /// Vision's overall score, −1 to 1, when it was wanted.
    public var score: Float?
    public var side: Int

    public init(utility: Bool, smallUtility: Bool? = nil, score: Float? = nil, side: Int) {
        self.utility = utility
        self.smallUtility = smallUtility
        self.score = score
        self.side = side
    }
}

/// `PhotoAssessing` by Vision: `isUtility` on the image indexing decoded, and
/// where a score is wanted, Vision again on the photograph at `smallSide`,
/// whose score ranks the photographs as Photos' does (spike 5).
public struct VisionAssessor: PhotoAssessing {
    /// Spike 5: at 427 Vision ranks as Photos does with Spearman 0.964, at
    /// 854 0.922, on the Intel iMac.
    public static let smallSide = 427

    /// Below this the image indexing decoded is the small one: a tile of an
    /// optimised library, read at 427 or 256. Vision is not asked twice.
    public static let smallEnough = 480

    public init() {}

    public var revision: String { "vision-\(AestheticsAssessor.revision)-\(Self.smallSide)" }

    public func assess(_ image: CGImage, small: (Int) -> CGImage?, wantsScore: Bool) throws -> AestheticVerdict {
        let side = max(image.width, image.height)
        guard let large = try AestheticsAssessor.scores(of: image) else { throw Unscored() }
        guard wantsScore else { return AestheticVerdict(utility: large.isUtility, side: side) }
        guard side > Self.smallEnough else {
            return AestheticVerdict(utility: large.isUtility, score: large.overall, side: side)
        }
        guard let image = small(Self.smallSide) ?? Self.scaled(image, longSide: Self.smallSide),
              let scores = try AestheticsAssessor.scores(of: image) else { throw Unscored() }
        return AestheticVerdict(
            utility: large.isUtility, smallUtility: scores.isUtility, score: scores.overall, side: side
        )
    }

    struct Unscored: Error {}

    /// For a source that cannot scale for itself. Vision ranks such an image
    /// less like Photos (`--probe-quality`, 2026-10-18), but better than not
    /// at all.
    static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
