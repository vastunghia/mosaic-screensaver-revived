// APP side of spike 3.
//
// Questions:
//   1. Can an ad-hoc signed app obtain PhotoKit authorisation on macOS 15?
//   2. How fast can thumbnails be extracted at tile resolution? (it sizes the first
//      indexing pass, which in the original was a progress bar lasting minutes)
//   3. How many photos are not available locally without downloading them from iCloud?
//   4. Is the result then readable by the saver without re-authorisation?
//
// It has to be a real signed .app, launched with `open`: from a shell it would inherit the
// Terminal's TCC identity (the lesson of spike 2).

import AppKit
import Photos

let MAX_ASSETS = 200         // a ceiling, to keep the spike short
let THUMB_SIZE = CGSize(width: 512, height: 288)

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ note: Notification) {
        say("SPIKE3 ===== APP side =====")
        say("SPIKE3 initial authorisation status: \(describe(PHPhotoLibrary.authorizationStatus(for: .readWrite)))")

        // `probe`: read the status and nothing else — do not request it, do not
        // index. This exists for the stable-signing-identity experiment: a rebuild
        // changes the cdhash, and the question is whether TCC notices. Requesting
        // authorisation would spoil the test, because a granted prompt would make
        // the two possible outcomes indistinguishable.
        if CommandLine.arguments.contains("probe") {
            say("SPIKE3 probe mode — no request, no indexing")
            NSApp.terminate(nil)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                say("SPIKE3 status after the request: \(self.describe(status))")
                guard status == .authorized || status == .limited else {
                    say("SPIKE3 DENIED — nothing to do")
                    NSApp.terminate(nil); return
                }
                if CommandLine.arguments.contains("bench") {
                    runBenchmark()
                } else {
                    self.index(limited: status == .limited)
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func describe(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        @unknown default:    return "unknown"
        }
    }

    private func index(limited: Bool) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: fetchOptions)

        say("SPIKE3 library: \(result.count) images\(limited ? " (LIMITED access, to the selection)" : "")")
        guard result.count > 0 else { say("SPIKE3 empty library"); return }

        try? FileManager.default.createDirectory(atPath: thumbsDirectory, withIntermediateDirectories: true)

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        // Deliberately NO: we want to measure the local case and count how many photos
        // would require a download from iCloud, not to wait on the network.
        options.isNetworkAccessAllowed = false

        var entries: [Entry] = []
        var notLocal = 0
        var failed = 0
        let howMany = min(MAX_ASSETS, result.count)
        let start = Date()

        for i in 0..<howMany {
            let asset = result.object(at: i)
            var image: NSImage?
            manager.requestImage(for: asset, targetSize: THUMB_SIZE, contentMode: .aspectFill,
                                 options: options) { img, info in
                image = img
                if (info?[PHImageResultIsInCloudKey] as? Bool) == true { notLocal += 1 }
            }
            guard let img = image, let entry = process(asset: asset, image: img, index: i) else {
                failed += 1; continue
            }
            entries.append(entry)
        }

        let elapsed = Date().timeIntervalSince(start)
        let index = Index(created: Date(), libraryTotal: result.count, entries: entries)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            let data = try enc.encode(index)
            // Atomic replacement: a requirement that came out of spike 2.
            try data.write(to: URL(fileURLWithPath: indexFile), options: .atomic)
        } catch {
            say("SPIKE3 writing the index FAILED: \(error)")
        }

        let perSec = elapsed > 0 ? Double(entries.count) / elapsed : 0
        say("SPIKE3 extracted \(entries.count)/\(howMany) thumbnails in \(String(format: "%.1f", elapsed))s "
            + "→ \(String(format: "%.1f", perSec)) photos/s")
        say("SPIKE3 iCloud only (skipped): \(notLocal) — failed for other reasons: \(failed)")
        if perSec > 0 {
            let estimate = Double(result.count) / perSec
            say("SPIKE3 estimate for the whole library of \(result.count): "
                + "\(String(format: "%.0f", estimate))s ≈ \(String(format: "%.1f", estimate / 60)) minutes")
        }
        say("SPIKE3 index in \(indexFile)")
        say("SPIKE3 done — now select ThumbGrid in System Settings")
    }

    /// Writes the JPEG and computes the average colour by resampling to 1×1: it is the
    /// lowest level of the "signature image" the plan foresees for M5.
    private func process(asset: PHAsset, image: NSImage, index i: Int) -> Entry? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }

        let name = String(format: "%04d.jpg", i)
        do { try jpeg.write(to: URL(fileURLWithPath: thumbsDirectory + "/" + name)) } catch { return nil }

        guard let average = averageColour(rep) else { return nil }
        return Entry(id: asset.localIdentifier, file: name,
                     r: average.0, g: average.1, b: average.2,
                     width: asset.pixelWidth, height: asset.pixelHeight)
    }

    private func averageColour(_ rep: NSBitmapImageRep) -> (Double, Double, Double)? {
        guard let ci = CIImage(bitmapImageRep: rep) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ])
        guard let out = filter?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
