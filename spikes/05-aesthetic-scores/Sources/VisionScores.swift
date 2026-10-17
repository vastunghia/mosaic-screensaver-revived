import AppKit
import Foundation
import Photos
import Vision

/// Question 5: Vision's aesthetics score on the photographs of Mosaic's index,
/// with its cost, written as CSV next to a small preview of each photograph.
/// With `sample`, on that many photographs drawn from the whole library instead,
/// for Macs that have no index; `previews` false keeps other people's photos
/// off the results.
///
///   Spike5Probe --vision <out dir> [--manifest <manifest.json> | --sample N] [--sizes 854,427]
///               [--limit N] [--no-previews]
@available(macOS 15.0, *)
func runVision(out: String, manifest: String, sample: Int?, sizes: [Int], limit: Int, previews: Bool) async {
    struct Manifest: Decodable { struct Entry: Decodable { let id: String }; let entries: [Entry] }
    let ids: ArraySlice<String>
    if let sample {
        ids = sampleIdentifiers(sample)
    } else {
        guard let data = FileManager.default.contents(atPath: manifest),
              let listed = try? JSONDecoder().decode(Manifest.self, from: data).entries.map(\.id).prefix(limit) else {
            print("cannot read \(manifest)"); return
        }
        ids = listed
    }
    try? FileManager.default.createDirectory(atPath: out + (previews ? "/previews" : ""), withIntermediateDirectories: true)
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
    var assets: [String: PHAsset] = [:]
    fetch.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
    print("vision: \(ids.count) identifiers, \(assets.count) assets, sizes \(sizes)")

    var csv = "id,uuid,size,width,height,fetch_ms,vision_ms,overall,is_utility\n"
    let manager = PHImageManager.default()
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.isNetworkAccessAllowed = false
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    let request = CalculateImageAestheticsScoresRequest()
    var visionTotal: [Int: Double] = [:], fetchTotal: [Int: Double] = [:], done: [Int: Int] = [:]
    let started = Date()

    for (n, id) in ids.enumerated() {
        guard let asset = assets[id] else { csv += "\(id),,,,,,,,missing\n"; continue }
        let uuid = String(id.split(separator: "/")[0])
        for size in sizes {
            let t0 = Date()
            var image: CGImage?
            manager.requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                                 contentMode: .aspectFit, options: options) { result, _ in
                image = result?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            let fetchMs = Date().timeIntervalSince(t0) * 1000
            guard let image else { csv += "\(id),\(uuid),\(size),,,\(Int(fetchMs)),,,unavailable\n"; continue }
            let t1 = Date()
            do {
                let observation = try await request.perform(on: image)
                let visionMs = Date().timeIntervalSince(t1) * 1000
                csv += "\(id),\(uuid),\(size),\(image.width),\(image.height),\(String(format: "%.1f", fetchMs)),\(String(format: "%.1f", visionMs)),\(observation.overallScore),\(observation.isUtility)\n"
                visionTotal[size, default: 0] += visionMs; fetchTotal[size, default: 0] += fetchMs; done[size, default: 0] += 1
            } catch {
                csv += "\(id),\(uuid),\(size),\(image.width),\(image.height),\(Int(fetchMs)),,,error \(error)\n"
            }
            if previews, size == sizes[0] { writePreview(image, to: "\(out)/previews/\(uuid).jpg") }
        }
        if (n + 1) % 256 == 0 {
            print("  \(n + 1) done, \(Int(Date().timeIntervalSince(started))) s")
        }
    }
    try? csv.write(toFile: out + "/vision.csv", atomically: true, encoding: .utf8)
    for size in sizes {
        let count = Double(max(done[size] ?? 0, 1))
        print("size \(size): \(done[size] ?? 0) scored, fetch \(String(format: "%.1f", (fetchTotal[size] ?? 0) / count)) ms, vision \(String(format: "%.1f", (visionTotal[size] ?? 0) / count)) ms per photo")
    }
    print("total \(Int(Date().timeIntervalSince(started))) s")
}

/// `count` images drawn from the library, the same ones on every run: the
/// smallest FNV-1a hashes of their identifiers.
func sampleIdentifiers(_ count: Int) -> ArraySlice<String> {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    var all: [(UInt64, String)] = []
    PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in asset.localIdentifier.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        all.append((hash, asset.localIdentifier))
    }
    return all.sorted { $0.0 < $1.0 }.map(\.1).prefix(count)
}

/// Previews of the photographs listed in `ids` (one UUID per line), for a page
/// that samples the whole library rather than the index.
func runPreviews(out: String, ids file: String, side: Int) {
    let uuids = (try? String(contentsOfFile: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: uuids.map { $0 + "/L0/001" }, options: nil)
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.isNetworkAccessAllowed = false
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    var written = 0
    fetch.enumerateObjects { asset, _, _ in
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                              contentMode: .aspectFit, options: options) { result, _ in
            guard let image = result?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            writePreview(image, to: "\(out)/\(asset.localIdentifier.split(separator: "/")[0]).jpg", side: side)
            written += 1
        }
    }
    print("previews: \(uuids.count) asked, \(fetch.count) found, \(written) written")
}

/// A preview `side` px on the long side, for the specimen pages.
func writePreview(_ image: CGImage, to path: String, side: Int = 320) {
    let scale = min(1, Double(side) / Double(max(image.width, image.height)))
    let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let small = context.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: small)
    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: URL(fileURLWithPath: path))
}
