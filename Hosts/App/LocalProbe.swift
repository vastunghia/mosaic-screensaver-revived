import Foundation
import MosaicCore
import MosaicPhotoKit
import MosaicPhotos
import PhotoIndex

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
    static func probe(_ source: any PhotoSource, name: String, count: Int, width: Int, seed: UInt64, csv: URL?) throws {
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
            let availability = Result { try library.localAvailability(of: id) }
            // What indexing gets, in the same breath, so the two are compared
            // on the same photograph while the library may still be changing.
            let indexed: String
            do {
                let image = try library.canonicalImage(for: id, maxPixelWidth: width)
                indexed = "\(image.width)"
            } catch PhotoSourceError.unavailable {
                indexed = "unavailable"
            } catch {
                indexed = "failed"
            }
            collected.append((id, library.pixelSize(of: id), availability, indexed))
        }
        let elapsed = Date().timeIntervalSince(started)
        let rows = collected.sorted
        print(String(format: "  %.1f s", elapsed))

        var local = 0, remote = 0, failed = 0
        var steps: [Int?: Int] = [:]
        var sides: [Int: Int] = [:]
        var flagged = 0
        var indexedByStep: [String: Int] = [:]
        var lines = ["id,original_width,original_height,original_bytes,largest_crop_width,largest_width,largest_height,in_cloud,ms,indexed"]
        for (id, original, result, indexed) in rows {
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
                "\(probe.inCloud)", "\(Int(probe.seconds * 1000))", indexed,
            ].joined(separator: ","))
            let reached = probe.largestCropWidth.map { "\($0) px" } ?? "nothing"
            let outcome = Int(indexed).map { $0 >= width - 1 ? "\(width)" : "narrower" } ?? indexed
            indexedByStep["\(reached) -> \(outcome)", default: 0] += 1

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
        print("  largest crop rendered -> what indexing at \(width) px got:")
        for (key, count) in indexedByStep.sorted(by: { $0.key < $1.key }) {
            print("    \(key): \(count)")
        }
        if let csv {
            try (lines.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
            print("  \(csv.path)")
        }
    }
}

private final class Rows: @unchecked Sendable {
    typealias Row = (PhotoID, (width: Int, height: Int)?, Result<PhotoKitPhotoSource.LocalAvailability, Error>, String)

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

/// `--probe-download N`: what fetching from iCloud costs, for the photographs
/// that fill the screen, or, at a width below theirs
/// (`--close-up-anchor-width 640`), for tiles the anchor's ring wants wider.
///
/// On an optimised library almost none of them is here larger than 854 px, so
/// full screen they are soft (2026-10-11). Asked at 1920 with the network
/// allowed, does PhotoKit fetch the whole original or only what was asked for?
/// For `N` photographs of the index that fill the screen, one at a time: what
/// is here before, the request and how long it took, and what is here after.
/// The space it took is not measured here: compare the Photos library on disk
/// before and after.
enum DownloadProbe {
    static func probe(index store: PhotoIndexStore, source: any PhotoSource, count: Int, width: Int, seed: UInt64) throws {
        guard let library = (source as? SubsetPhotoSource<PhotoKitPhotoSource>)?.base ?? source as? PhotoKitPhotoSource else {
            print("probe-download: only the Photos library can be probed")
            return
        }
        let index = try IndexedPhotoSource(store: store)
        _ = try library.photos()
        let fetching = PhotoKitPhotoSource(scope: library.scope, allowsNetworkAccess: true)
        _ = try fetching.photos()

        var rng = SplitMix64(seed: seed)
        let narrowest = index.manifest.thumbnailWidth - 1
        let candidates: [IndexEntry]
        let described: String
        if width >= narrowest {
            // Full width only: a small original has nothing more to fetch.
            candidates = index.entries.filter { $0.canFillScreen && $0.pixelWidth >= narrowest }
            described = "photographs that fill the screen"
        } else {
            // Below the screen's width, what the anchor's ring wants: tiles
            // narrower than asked, not subjects, whose original is wider.
            let subjects = Set(index.manifest.subjects)
            candidates = index.entries.filter { entry in
                guard !entry.canFillScreen, entry.pixelWidth < width - 1, !subjects.contains(entry.id),
                      let size = library.pixelSize(of: entry.photoID) else { return false }
                return Int(CanonicalCrop.rect(width: size.width, height: size.height).width) >= width
            }
            described = "tiles narrower than that, not subjects, whose original is wider"
        }
        let sample = Array(rng.shuffled(candidates).prefix(count))
        print("probe-download: \(sample.count) of the \(candidates.count) \(described), at \(width) px")
        print("id,original,before_bytes,before_crop,fetched,seconds,after_bytes,after_crop")

        var fetched = 0, originalsAfter = 0, seconds = 0.0
        for entry in sample {
            let id = entry.photoID
            let original = library.pixelSize(of: id).map { "\($0.width)x\($0.height)" } ?? ""
            let before = try library.localAvailability(of: id)
            let started = Date()
            let result: String
            do {
                let image = try fetching.uprightImage(for: id, cropWidth: width)
                result = "\(image.width)x\(image.height)"
                fetched += 1
            } catch {
                result = "\(error)"
            }
            let elapsed = Date().timeIntervalSince(started)
            seconds += elapsed
            let after = try library.localAvailability(of: id)
            if after.originalBytes != nil { originalsAfter += 1 }
            func text(_ value: Int?) -> String { value.map { "\($0)" } ?? "" }
            let columns: [String] = [
                id.rawValue, original, text(before.originalBytes), text(before.largestCropWidth),
                result, String(format: "%.1f", elapsed), text(after.originalBytes), text(after.largestCropWidth),
            ]
            print(columns.joined(separator: ","))
        }
        print(String(format: "  %d of %d fetched in %.1f s; %d have their original here afterwards",
                     fetched, sample.count, seconds, originalsAfter))
    }
}
