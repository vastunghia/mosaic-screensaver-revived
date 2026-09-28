import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos

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
