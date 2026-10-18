import Foundation

/// Vision's overall score, −1 to 1, carried onto Photos' aesthetic scale, 0
/// to 1, so that a photograph Photos has not analysed can be held to the bar
/// of those it has (`Culling`).
///
/// The two scores rank photographs almost alike (Spearman 0.964 at 427 px)
/// but on different scales, so the map is monotone, by quantiles: a Vision
/// score goes to its quantile among Vision's, then to Photos' score at the
/// same quantile. Fitted on the 2048 photographs of Sergio's index, Vision at
/// 427 px as `VisionAssessor` asks for it, by `spikes/05-aesthetic-scores/fitmap.py`;
/// linear between knots, which is within 0.027 of the step map spike 5 judged.
/// Close to the identity above 0.3; it bends only at the bottom, where
/// Vision goes negative and Photos stays at 0 to 0.2.
public enum VisionScoreMap {
    /// Part of `VisionAssessor.revision` in spirit, but not in fact: the map
    /// is applied when a build judges, to the raw score the manifest keeps, so
    /// a new one asks Vision nothing.
    public static let revision = 1

    /// (Vision, Photos), both increasing.
    static let knots: [(vision: Double, photos: Double)] = [
        (-0.9871, 0.0000),
        (-0.5600, 0.0346),
        (-0.2751, 0.1271),
        (-0.1176, 0.1940),
        (0.0000, 0.2249),
        (0.1061, 0.2437),
        (0.1936, 0.2556),
        (0.2086, 0.2620),
        (0.2306, 0.2734),
        (0.2426, 0.2817),
        (0.2563, 0.2896),
        (0.2668, 0.2969),
        (0.2717, 0.3030),
        (0.2778, 0.3088),
        (0.2827, 0.3149),
        (0.2937, 0.3235),
        (0.3088, 0.3386),
        (0.3254, 0.3555),
        (0.3491, 0.3782),
        (0.3706, 0.3965),
        (0.3892, 0.4138),
        (0.4065, 0.4312),
        (0.4216, 0.4487),
        (0.4375, 0.4636),
        (0.4556, 0.4790),
        (0.4729, 0.4956),
        (0.4907, 0.5137),
        (0.5132, 0.5352),
        (0.5332, 0.5547),
        (0.5537, 0.5767),
        (0.5830, 0.6040),
        (0.6182, 0.6406),
        (0.6743, 0.7036),
        (0.7256, 0.7534),
        (0.7847, 0.8071),
        (0.9258, 0.9355),
    ]

    public static func photosScore(forVision score: Double) -> Double {
        guard let first = knots.first, let last = knots.last else { return score }
        if score <= first.vision { return first.photos }
        if score >= last.vision { return last.photos }
        let upper = knots.firstIndex { $0.vision > score }!
        let (low, high) = (knots[upper - 1], knots[upper])
        return low.photos + (high.photos - low.photos) * (score - low.vision) / (high.vision - low.vision)
    }
}
