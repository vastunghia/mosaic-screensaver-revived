import Foundation
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos

/// `--probe-local N`: what this Mac holds of the library without asking iCloud.
///
/// With "Optimize Mac Storage" part of the library has no original here, and
/// what PhotoKit then renders is not documented: nothing, or a derivative of
/// some size. `--verify-canonical` cannot tell — asked for 854 px with
/// `.exact`, PhotoKit could scale a smaller derivative up and the result would
/// pass. So this asks for the largest image PhotoKit will make from local data
/// alone, and whether the original's bytes are here at all.
///
/// The sample is drawn from the subset with the seed, as `--verify-canonical`
/// draws it; with `N` at least the subset's size it is the whole subset.
enum LocalProbe {
    static func probe(_ source: any PhotoSource, name: String, count: Int, seed: UInt64, csv: URL?) throws {
        guard let library = (source as? SubsetPhotoSource<PhotoKitPhotoSource>)?.base ?? source as? PhotoKitPhotoSource else {
            print("probe-local: only the Photos library can be probed")
            return
        }
        let all = try source.photos()
        var rng = SplitMix64(seed: seed)
        let sample = Array(rng.shuffled(all).prefix(count))
        print("probe-local: \(sample.count) of \(all.count) photographs in \(name), seed \(seed), no network")

        let collected = Rows()
        let started = Date()
        DispatchQueue.concurrentPerform(iterations: sample.count) { offset in
            let id = sample[offset].id
            collected.append((id, library.pixelSize(of: id), Result { try library.localAvailability(of: id) }))
        }
        let elapsed = Date().timeIntervalSince(started)
        let rows = collected.sorted
        print(String(format: "  %.1f s", elapsed))

        var local = 0, remote = 0, failed = 0
        var steps: [Int?: Int] = [:]
        var sides: [Int: Int] = [:]
        var flagged = 0
        var lines = ["id,original_width,original_height,original_bytes,largest_crop_width,largest_width,largest_height,in_cloud,ms"]
        for (id, original, result) in rows {
            guard case .success(let probe) = result else {
                failed += 1
                continue
            }
            lines.append([
                id.rawValue,
                original.map { "\($0.width)" } ?? "", original.map { "\($0.height)" } ?? "",
                probe.originalBytes.map { "\($0)" } ?? "",
                probe.largestCropWidth.map { "\($0)" } ?? "",
                probe.largest.map { "\($0.width)" } ?? "", probe.largest.map { "\($0.height)" } ?? "",
                "\(probe.inCloud)", "\(Int(probe.seconds * 1000))",
            ].joined(separator: ","))

            if probe.originalBytes != nil {
                local += 1
                continue
            }
            remote += 1
            steps[probe.largestCropWidth, default: 0] += 1
            if let largest = probe.largest { sides[max(largest.width, largest.height), default: 0] += 1 }
            if probe.inCloud { flagged += 1 }
        }

        print("  original here: \(local); original only in iCloud: \(remote); failed: \(failed)")
        if remote > 0 {
            print("  of those, the largest crop width rendered (ladder \(PhotoKitPhotoSource.ladder.map(String.init).joined(separator: " ")) px):")
            for (step, count) in steps.sorted(by: { ($0.key ?? 0) > ($1.key ?? 0) }) {
                print("    \(step.map { "\($0) px" } ?? "nothing"): \(count)")
            }
            let top = sides.sorted { $0.value > $1.value }.prefix(10)
                .map { "\($0.key) px ×\($0.value)" }.joined(separator: ", ")
            print("  longest side of the largest image, as PhotoKit sized it: \(top)")
            print("  \(flagged) said 'in iCloud' when they stopped, \(remote - flagged) stopped without saying")
        }
        if let csv {
            try (lines.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
            print("  \(csv.path)")
        }
    }
}

private final class Rows: @unchecked Sendable {
    typealias Row = (PhotoID, (width: Int, height: Int)?, Result<PhotoKitPhotoSource.LocalAvailability, Error>)

    private let lock = NSLock()
    private var rows: [Row] = []

    func append(_ row: Row) {
        lock.lock(); rows.append(row); lock.unlock()
    }

    var sorted: [Row] {
        lock.lock(); defer { lock.unlock() }
        return rows.sorted { $0.0.rawValue < $1.0.rawValue }
    }
}
