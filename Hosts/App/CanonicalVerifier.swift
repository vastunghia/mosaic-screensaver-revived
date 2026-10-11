import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex

/// `--verify-canonical N`: the postcondition of `PhotoSource.canonicalImage`,
/// checked on real photographs, and timed.
///
/// A unit test cannot do this for PhotoKit — there is no library in a test —
/// and the postcondition is exactly the kind of thing that fails plausibly: a
/// source that hands back a smaller derivative than was asked for still makes
/// mosaics, only softer ones, and nothing downstream would notice.
///
/// The sample is drawn with the seed, so `--seed` picks photographs never
/// touched before, which is how the **cold** rate is measured.
enum CanonicalVerifier {
    static func verify(
        _ source: any PhotoSource, name: String, count: Int, width: Int, seed: UInt64
    ) throws -> Bool {
        let all = try source.photos()
        var rng = SplitMix64(seed: seed)
        let sample = Array(rng.shuffled(all).prefix(count))
        print("verify: \(sample.count) of \(all.count) photographs in \(name), at \(width) px, seed \(seed)")

        let results = Results()
        let started = Date()
        DispatchQueue.concurrentPerform(iterations: sample.count) { offset in
            let id = sample[offset].id
            do {
                let image = try source.canonicalImage(for: id, maxPixelWidth: width)
                results.record(id, problems: problems(of: image, width: width),
                               width: image.width, asked: width)
            } catch PhotoSourceError.unavailable {
                results.unavailable(id)
            } catch {
                results.failed(id, error)
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        let report = results.report
        print(String(
            format: "  %.1f s, %.1f photographs/s (%d threads)",
            elapsed, Double(sample.count) / max(elapsed, 0.001), ProcessInfo.processInfo.activeProcessorCount
        ))
        print("  \(report.passed) as promised, \(report.narrower) narrower than asked, "
              + "\(report.broken.count) breaking the contract, "
              + "\(report.unavailable) not on this Mac, \(report.failures.count) failed")
        let widths = report.widths.sorted { $0.key > $1.key }.prefix(8)
            .map { "\($0.key) px ×\($0.value)" }.joined(separator: ", ")
        print("  widths: \(widths)")
        // Narrower than asked is right only when the original's crop is
        // narrower too; anything else is PhotoKit handing back a derivative.
        let library = (source as? SubsetPhotoSource<PhotoKitPhotoSource>)?.base ?? source as? PhotoKitPhotoSource
        for (id, got) in report.narrowerOnes.sorted(by: { $0.1 < $1.1 }).prefix(30) {
            // 0×0 for a photograph whose size PhotoKit does not know yet.
            let original = library?.pixelSize(of: id).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            let cropWidth = original.map { Int(CanonicalCrop.rect(width: $0.width, height: $0.height).width) }
            // One pixel short is PhotoKit's rounding, seen on originals of every
            // size; more than that would be a derivative smaller than asked for.
            let verdict = cropWidth.map {
                $0 <= got ? "original is that small"
                    : min($0, width) - got <= 1 ? "a pixel short (PhotoKit rounding)"
                    : "SMALLER THAN THE ORIGINAL ALLOWS"
            } ?? ""
            print("  narrower \(id.rawValue): \(got) px; original "
                  + (original.map { "\($0.width)×\($0.height), crop \(cropWidth!) px" } ?? "unknown")
                  + " — \(verdict)")
        }
        for (id, problems) in report.broken.prefix(20) {
            print("  BROKEN \(id.rawValue): \(problems.joined(separator: "; "))")
        }
        for (id, error) in report.failures.prefix(20) {
            print("  FAILED \(id.rawValue): \(error)")
        }
        return report.broken.isEmpty && report.failures.isEmpty
    }

    /// What is wrong with an image that should be a canonical crop at most
    /// `width` across. Narrower is not wrong — the original may be small — and
    /// is counted apart so a source that always comes back small shows up.
    static func problems(of image: CGImage, width: Int) -> [String] {
        var problems: [String] = []
        if image.width > width {
            problems.append("\(image.width) px wide, asked for at most \(width)")
        }
        let expected = CanonicalAspect.height(forWidth: image.width)
        if abs(image.height - expected) > 1 {
            problems.append("\(image.width)×\(image.height), not 16:9 (expected height \(expected))")
        }
        if image.colorSpace?.name != CGColorSpace.sRGB {
            problems.append("colour space \(image.colorSpace?.name.map { $0 as String } ?? "none"), not sRGB")
        }
        return problems
    }
}

private final class Results: @unchecked Sendable {
    struct Report {
        var passed = 0
        var narrower = 0
        var narrowerOnes: [(PhotoID, Int)] = []
        var unavailable = 0
        var broken: [(PhotoID, [String])] = []
        var failures: [(PhotoID, Error)] = []
        var widths: [Int: Int] = [:]
    }

    private let lock = NSLock()
    private var current = Report()

    var report: Report {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func record(_ id: PhotoID, problems: [String], width: Int, asked: Int) {
        lock.lock(); defer { lock.unlock() }
        current.widths[width, default: 0] += 1
        if !problems.isEmpty {
            current.broken.append((id, problems))
        } else if width < asked {
            current.narrower += 1
            current.narrowerOnes.append((id, width))
        } else {
            current.passed += 1
        }
    }

    func unavailable(_ id: PhotoID) {
        lock.lock(); current.unavailable += 1; lock.unlock()
    }

    func failed(_ id: PhotoID, _ error: Error) {
        lock.lock(); current.failures.append((id, error)); lock.unlock()
    }
}

/// `--verify-windows N`: that a close-up from the originals is cut where the
/// index cut the thumbnail, on real photographs whose window moved.
///
/// The whole point of storing the window (SPEC § 4) is that the crossfade from
/// tile to close-up does not jump. Both images are reduced to an 8x8 grid of
/// linear colours and compared; the centre crop of the same original is the
/// control, and has to be much further off than the window is.
enum WindowVerifier {
    static func verify(_ indexed: IndexedPhotoSource, count: Int, width: Int) throws -> Bool {
        guard let originals = indexed.originals else {
            print("verify-windows: no originals behind the index")
            return false
        }
        let all = indexed.entries.filter { $0.cropStart != nil }
        let moved = all.prefix(count)
        print("verify-windows: \(moved.count) of the \(all.count) photographs whose window moved, of \(indexed.entries.count); "
              + "close-ups at \(width) px against \(indexed.manifest.thumbnailWidth) px thumbnails")

        var windowErrors: [Double] = []
        var centreErrors: [Double] = []
        for entry in moved {
            let id = entry.photoID
            let thumbnail = try ImageSampling.signature(
                of: indexed.canonicalImage(for: id, maxPixelWidth: indexed.manifest.thumbnailWidth), side: 8
            )
            let closeUp = try ImageSampling.signature(of: indexed.canonicalImage(for: id, maxPixelWidth: width), side: 8)
            let centre = try ImageSampling.signature(of: originals.canonicalImage(for: id, maxPixelWidth: width), side: 8)
            windowErrors.append(distance(thumbnail, closeUp))
            centreErrors.append(distance(thumbnail, centre))
        }
        windowErrors.sort()
        centreErrors.sort()
        func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values[values.count / 2] }
        print(String(format: "  thumbnail vs close-up: median %.4f, worst %.4f (mean |Δ| per channel, linear)",
                     median(windowErrors), windowErrors.last ?? 0))
        print(String(format: "  thumbnail vs centre crop (control): median %.4f, best %.4f",
                     median(centreErrors), centreErrors.first ?? 0))
        let passed = (windowErrors.last ?? 0) < median(centreErrors) / 2
        print(passed ? "  close-ups follow the window" : "  CLOSE-UPS DO NOT FOLLOW THE WINDOW")
        return passed
    }

    private static func distance(_ a: TileSignature, _ b: TileSignature) -> Double {
        let total = zip(a.cells, b.cells).reduce(0.0) { sum, pair in
            sum + abs(pair.0.r - pair.1.r) + abs(pair.0.g - pair.1.g) + abs(pair.0.b - pair.1.b)
        }
        return total / Double(a.cells.count * 3)
    }
}
