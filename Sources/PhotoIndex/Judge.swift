import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos

/// Vision's part in leaving photographs out of a filled subset (evolution 4):
/// what a build holds a decoded photograph to, once `Culling` has left out
/// the screenshots and the weakest of those Photos scored.
///
/// A photograph goes if Vision calls it a utility shot on either image, or if
/// Photos has no score for it and Vision's, mapped onto Photos' scale, is below
/// the bar of its month. It goes as an unavailable photograph does: another is
/// chosen in its place.
struct Judge: Sendable {
    /// Thrown by `inspect` to stop reading a photograph that goes.
    struct Rejection: Error {}

    let assessor: any PhotoAssessing
    let culling: Culling
    let book: AssessmentBook

    /// The assessment of `photo` still good: the same pixels, the same
    /// revision, and a score if Photos has none now.
    func current(_ photo: PhotoDescriptor) -> PhotoAssessment? {
        guard let assessment = book[photo.id.rawValue], assessment.versionToken == photo.versionToken,
              assessment.revision == assessor.revision,
              assessment.score != nil || culling.hasScore(photo.id) else { return nil }
        return assessment
    }

    /// Whether `photo` goes, or nil when it has not been looked at.
    func rejected(_ photo: PhotoDescriptor) -> Bool? {
        current(photo).map { rejects($0, photo) }
    }

    func rejects(_ assessment: PhotoAssessment, _ photo: PhotoDescriptor) -> Bool {
        assessment.rejects(photo, by: culling)
    }

    /// Looks at `image`, the whole of `photo` as indexing decoded it, unless
    /// it was looked at before, and throws `Rejection` if it goes. A
    /// photograph Vision cannot read stays, and is looked at again next time.
    func inspect(_ image: CGImage, of photo: PhotoDescriptor, from source: some PhotoSource) throws {
        let assessment: PhotoAssessment
        if let known = current(photo) {
            assessment = known
        } else {
            guard let verdict = try? assessor.assess(
                image, small: { source.wholeImage(for: photo.id, longSide: $0) }, wantsScore: !culling.hasScore(photo.id)
            ) else { return }
            assessment = PhotoAssessment(
                id: photo.id.rawValue, versionToken: photo.versionToken, revision: assessor.revision,
                utility: verdict.utility, smallUtility: verdict.smallUtility, score: verdict.score, side: verdict.side
            )
            book.add(assessment)
        }
        if rejects(assessment, photo) { throw Rejection() }
    }
}

extension PhotoAssessment {
    /// Whether `photo`, assessed as this says, is left out: a utility shot
    /// on either image; or, when Photos has no score for it, Vision's score
    /// mapped onto Photos' scale below the bar of its month.
    public func rejects(_ photo: PhotoDescriptor, by culling: Culling) -> Bool {
        if utility || smallUtility == true { return true }
        guard !culling.hasScore(photo.id), let score else { return false }
        return VisionScoreMap.photosScore(forVision: Double(score)) < culling.bar(for: photo)
    }
}

/// Every assessment a build knows, from the manifest and from every core.
final class AssessmentBook: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: PhotoAssessment]

    init(_ assessments: [PhotoAssessment]) {
        byID = Dictionary(assessments.map { ($0.id, $0) }) { _, last in last }
    }

    subscript(id: String) -> PhotoAssessment? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    func add(_ assessment: PhotoAssessment) {
        lock.lock(); defer { lock.unlock() }
        byID[assessment.id] = assessment
    }

    /// Sorted by identifier, those of `ids` only when given: the photographs
    /// gone from the library are forgotten.
    func assessments(of ids: Set<String>? = nil) -> [PhotoAssessment] {
        lock.lock(); defer { lock.unlock() }
        return byID.values.filter { ids?.contains($0.id) ?? true }.sorted { $0.id < $1.id }
    }
}
