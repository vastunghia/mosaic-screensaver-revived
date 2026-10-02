import CoreGraphics
import Foundation

/// Where the 16:9 window goes when a photograph has faces in it (SPEC § 4).
///
/// The window is always the largest 16:9 rectangle the photograph holds — the
/// same size `CanonicalCrop.rect` gives — so it can only slide, along the one
/// axis where the photograph is longer than 16:9. The rule: **cut as few faces
/// as possible**, a face being cut unless its whole rectangle is inside the
/// window, and among the positions that do that, take the one **nearest the
/// centre**. Without faces, or with no room to slide, that is the centre crop.
///
/// Two refinements, both from looking at the `faces` specimen (2026-10-02):
///
/// - A face is kept with **the head above it**: a detector's rectangle runs
///   from brow to chin, and a window pushed to its edge took hair and hats off.
///   The rectangle grows upwards by `headroom` of its height — unless that no
///   longer fits in the window, when the face alone has to do.
/// - Between positions that keep as many faces, the one keeping **the most face
///   area** wins before the nearest to the centre: otherwise a child's doll
///   near the middle beat the head of the person holding it.
/// - A face **the photographer already cut** — one whose rectangle reaches the
///   frame of the photograph — does not count at all (decided 2026-10-02): the
///   window would move to save what was never whole, and in the specimen it
///   took a hat off the subject to keep half a child at the bottom edge.
///
/// Pure geometry: no Vision here. Where the rectangles come from is the
/// indexer's business, and keeping it out is what lets this be tested exactly.
public enum FaceAwareCrop {
    public struct Choice: Equatable, Sendable {
        /// The window, in the pixels of the image the faces were found in.
        public let rect: CGRect
        /// Faces this window cuts, and the centre window would have cut — of
        /// those that count: not the ones the photograph's frame already cut.
        public let cut: Int
        public let centreCut: Int
        /// How far the window moved from the centre, in pixels along its free
        /// axis; negative is up or left.
        public let shift: Int
        /// The room the window had to move in, either way: `shift` is at most
        /// this in magnitude.
        public let slack: Int
    }

    /// How much head goes above a face, as a share of the face's height.
    public static let headroom = 0.5

    /// What has to be inside the window for a face to count as whole: the face
    /// and the head above it.
    public static func head(of face: CGRect) -> CGRect {
        CGRect(x: face.minX, y: face.minY - face.height * headroom,
               width: face.width, height: face.height * (1 + headroom))
    }

    /// Whether the photograph's own frame already cuts a face: its rectangle
    /// reaches the edge, within a pixel. Such a face is not counted, either way.
    public static func isCutByFrame(_ face: CGRect, width: Int, height: Int) -> Bool {
        face.minX <= 1 || face.minY <= 1
            || face.maxX >= CGFloat(width - 1) || face.maxY >= CGFloat(height - 1)
    }

    /// `faces` are rectangles in the pixels of a `width × height` image, origin
    /// at the top left — the convention of `CGImage.cropping(to:)`.
    public static func choose(width: Int, height: Int, faces: [CGRect]) -> Choice {
        let centre = CanonicalCrop.rect(width: width, height: height)
        let horizontal = centre.width < CGFloat(width)
        let length = horizontal ? width : height
        let window = Int(horizontal ? centre.width : centre.height)
        let middle = Int(horizontal ? centre.minX : centre.minY)
        let room = length - window

        // The positions at which each face would be whole, as a closed range
        // of the window's leading edge. Clipped to the image, because the head
        // above a face may run off the top. One longer than the window never fits.
        let image = CGRect(x: 0, y: 0, width: width, height: height)
        func range(of rect: CGRect) -> ClosedRange<Int>? {
            let clipped = rect.intersection(image)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            let start = Int((horizontal ? clipped.minX : clipped.minY).rounded(.down))
            let end = Int((horizontal ? clipped.maxX : clipped.maxY).rounded(.up))
            let low = max(0, end - window)
            let high = min(room, start)
            return low <= high ? low...high : nil
        }
        let counted = faces.filter { !isCutByFrame($0, width: width, height: height) }
        let kept: [(range: ClosedRange<Int>, area: Double)] = counted.compactMap { face in
            guard let range = range(of: head(of: face)) ?? range(of: face) else { return nil }
            return (range, Double(face.width * face.height))
        }
        let total = counted.count

        func whole(at position: Int) -> (count: Int, area: Double) {
            kept.reduce((0, 0)) { $1.range.contains(position) ? ($0.0 + 1, $0.1 + $1.area) : $0 }
        }

        // Count and area are constant between range ends, so the best position
        // is either the centre or one of the ends — whichever end of a best run
        // is nearer the centre, when the centre is not in one.
        var best = middle
        var bestWhole = whole(at: middle)
        for position in kept.flatMap({ [$0.range.lowerBound, $0.range.upperBound] }) {
            let here = whole(at: position)
            let nearer = abs(position - middle) < abs(best - middle)
                || (abs(position - middle) == abs(best - middle) && position < best)
            if (here.count, here.area) > (bestWhole.count, bestWhole.area)
                || (here.count == bestWhole.count && here.area == bestWhole.area && nearer) {
                best = position
                bestWhole = here
            }
        }

        let rect = horizontal
            ? CGRect(x: best, y: 0, width: window, height: Int(centre.height))
            : CGRect(x: 0, y: best, width: Int(centre.width), height: window)
        return Choice(
            rect: rect,
            cut: total - bestWhole.count,
            centreCut: total - whole(at: middle).count,
            shift: best - middle,
            slack: max(middle, room - middle)
        )
    }
}
