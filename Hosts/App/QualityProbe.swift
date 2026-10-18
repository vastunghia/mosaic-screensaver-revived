import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex

/// `--probe-quality N`: which image Vision's aesthetics should be run on, and
/// what it costs while indexing (evolution 4, step 0).
///
/// Spike 5 gave Vision the whole photograph at 854 and 427 px on the long side,
/// asked from PhotoKit for the purpose. Indexing already holds the whole
/// photograph, upright, before the crop: at 854 px *of crop*, which is the
/// spike's image for a landscape and a larger one for a portrait. This runs,
/// for `N` photographs of the subset and on every core as indexing does:
///
/// - Vision on that upright image;
/// - Vision on a second request at 427 px on the long side, the image the map
///   onto Photos' scale was fitted on;
/// - Vision on the upright image scaled down to 427 px here, which needs no
///   request;
/// - Vision on PhotoKit's own rendering at 427, aspectFit, as the spike asked
///   (`PhotoKitPhotoSource.wholeImage`).
///
/// A first run also had the async API the spike used, on the second request's
/// image: on 2048 photographs it agreed with the synchronous request to the
/// last bit (2026-10-18), and was taken out.
///
/// One row per photograph, with the times, in the CSV.
enum QualityProbe {
    static func probe(
        _ source: any PhotoSource, name: String, count: Int, width: Int, seed: UInt64, serial: Bool, csv: URL?
    ) throws {
        guard let library = (source as? SubsetPhotoSource<PhotoKitPhotoSource>)?.base ?? source as? PhotoKitPhotoSource else {
            print("probe-quality: only the Photos library can be probed")
            return
        }
        let all = try source.photos()
        var rng = SplitMix64(seed: seed)
        let sample = Array(rng.shuffled(all).prefix(count))
        print("probe-quality: \(sample.count) of \(all.count) photographs in \(name), seed \(seed), "
              + "\(serial ? "one at a time" : "on every core"), no network")

        // The first request is slow while Vision loads its model (2 s cold in
        // the spike): out of the timings.
        if let first = sample.first, let image = try? library.uprightImage(for: first.id, cropWidth: width) {
            _ = try? AestheticsAssessor.scores(of: image)
        }

        let rows = Rows()
        let started = Date()
        let work: @Sendable (Int) -> Void = { offset in
            rows.append(measure(sample[offset], library: library, width: width))
        }
        if serial {
            for offset in sample.indices { work(offset) }
        } else {
            DispatchQueue.concurrentPerform(iterations: sample.count, execute: work)
        }
        let elapsed = Date().timeIntervalSince(started)
        let measured = rows.sorted
        print(String(format: "  %.1f s wall, %.1f ms a photograph", elapsed, elapsed * 1000 / Double(max(1, sample.count))))

        func mean(_ values: [Double]) -> String {
            values.isEmpty ? "–" : String(format: "%.1f", values.reduce(0, +) / Double(values.count))
        }
        let done = measured.filter { $0.large != nil }
        print("  scored \(done.count), failed or not here \(measured.count - done.count)")
        print("  upright \(width): fetch \(mean(done.map(\.uprightMs))) ms, vision \(mean(done.map(\.largeMs))) ms")
        print("  request 427: fetch \(mean(done.compactMap(\.requestMs))) ms, vision \(mean(done.compactMap(\.smallMs))) ms")
        print("  reduced 427: scaling \(mean(done.compactMap(\.reduceMs))) ms, vision \(mean(done.compactMap(\.reducedMs))) ms")
        let utility = (
            large: done.filter { $0.large?.isUtility == true }.count,
            small: done.filter { $0.small?.isUtility == true }.count,
            reduced: done.filter { $0.reduced?.isUtility == true }.count
        )
        print("  isUtility: upright \(utility.large), request 427 \(utility.small), reduced 427 \(utility.reduced)")
        print("  exact 427 (aspectFit, as spike 5): fetch \(mean(done.compactMap(\.exactMs))) ms, "
              + "vision \(mean(done.compactMap(\.exactVisionMs))) ms, isUtility \(done.filter { $0.exactScores?.isUtility == true }.count)")

        if let csv {
            var lines = [
                "id,original_width,original_height,upright_width,upright_height,upright_ms,large_ms,large_overall,large_utility,"
                    + "request_width,request_height,request_ms,small_ms,small_overall,small_utility,"
                    + "reduced_width,reduced_height,reduce_ms,reduced_ms,reduced_overall,reduced_utility,"
                    + "exact_width,exact_height,exact_ms,exact_vision_ms,exact_overall,exact_utility,error",
            ]
            for row in measured { lines.append(cells(of: row).joined(separator: ",")) }
            try (lines.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
            print("  \(csv.path)")
        }
    }

    private static func cells(of row: Row) -> [String] {
        func size(_ size: Size?) -> [String] {
            [size.map { "\($0.width)" } ?? "", size.map { "\($0.height)" } ?? ""]
        }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
        func scores(_ scores: AestheticsAssessor.Scores?) -> [String] {
            [scores.map { "\($0.overall)" } ?? "", scores.map { "\($0.isUtility)" } ?? ""]
        }
        var cells = [row.id]
        cells += size(row.original)
        cells += size(row.upright)
        cells += [ms(row.uprightMs), ms(row.largeMs)]
        cells += scores(row.large)
        cells += size(row.request)
        cells += [ms(row.requestMs), ms(row.smallMs)]
        cells += scores(row.small)
        cells += size(row.reducedSize)
        cells += [ms(row.reduceMs), ms(row.reducedMs)]
        cells += scores(row.reduced)
        cells += size(row.exact)
        cells += [ms(row.exactMs), ms(row.exactVisionMs)]
        cells += scores(row.exactScores)
        cells.append(row.error ?? "")
        return cells
    }

    struct Row: Sendable {
        var id: String
        var original: Size?
        var upright: Size?
        var uprightMs: Double = 0
        var large: AestheticsAssessor.Scores?
        var largeMs: Double = 0
        var request: Size?
        var requestMs: Double?
        var small: AestheticsAssessor.Scores?
        var smallMs: Double?
        var reducedSize: Size?
        var reduceMs: Double?
        var reduced: AestheticsAssessor.Scores?
        var reducedMs: Double?
        var exact: Size?
        var exactMs: Double?
        var exactScores: AestheticsAssessor.Scores?
        var exactVisionMs: Double?
        var error: String?
    }

    struct Size: Sendable {
        var width: Int
        var height: Int
    }

    static let smallSide = 427

    private static func measure(_ descriptor: PhotoDescriptor, library: PhotoKitPhotoSource, width: Int) -> Row {
        let id = descriptor.id
        var row = Row(id: id.rawValue, original: library.pixelSize(of: id).map { Size(width: $0.width, height: $0.height) })
        func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
            let start = Date()
            let value = try body()
            return (value, Date().timeIntervalSince(start) * 1000)
        }
        do {
            let (upright, uprightMs) = try timed { try library.uprightImage(for: id, cropWidth: width) }
            row.upright = Size(width: upright.width, height: upright.height)
            row.uprightMs = uprightMs
            (row.large, row.largeMs) = try timed { try AestheticsAssessor.scores(of: upright) }

            // The whole photograph at 427 on its long side, asked as indexing
            // asks: by the width of its crop.
            if let original = row.original, original.width > 0, original.height > 0 {
                let crop = CanonicalCrop.rect(width: original.width, height: original.height)
                let scale = Double(smallSide) / Double(max(original.width, original.height))
                let cropWidth = max(1, Int((crop.width * scale).rounded()))
                if let (image, requestMs) = try? timed({ try library.uprightImage(for: id, cropWidth: cropWidth) }) {
                    row.request = Size(width: image.width, height: image.height)
                    row.requestMs = requestMs
                    let (small, smallMs) = try timed { try AestheticsAssessor.scores(of: image) }
                    row.small = small
                    row.smallMs = smallMs
                }
            }

            // As spike 5 asked: aspectFit at 427, PhotoKit's own scaling.
            let (exact, exactMs) = timed { library.wholeImage(for: id, longSide: smallSide) }
            if let image = exact {
                row.exact = Size(width: image.width, height: image.height)
                row.exactMs = exactMs
                (row.exactScores, row.exactVisionMs) = try timed { try AestheticsAssessor.scores(of: image) }
            }

            let (reduced, reduceMs) = timed { scaled(upright, longSide: smallSide) }
            if let reduced {
                row.reducedSize = Size(width: reduced.width, height: reduced.height)
                row.reduceMs = reduceMs
                let (scores, reducedMs) = try timed { try AestheticsAssessor.scores(of: reduced) }
                row.reduced = scores
                row.reducedMs = reducedMs
            }
        } catch PhotoSourceError.unavailable {
            row.error = "unavailable"
        } catch {
            row.error = "\(error)".replacingOccurrences(of: ",", with: ";")
        }
        return row
    }

    private static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
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

private final class Rows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [QualityProbe.Row] = []

    func append(_ row: QualityProbe.Row) {
        lock.lock(); rows.append(row); lock.unlock()
    }

    var sorted: [QualityProbe.Row] {
        lock.lock(); defer { lock.unlock() }
        return rows.sorted { $0.id < $1.id }
    }
}
