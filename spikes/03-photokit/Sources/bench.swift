// Measurement bench: are the estimated 30 minutes for the whole library a PhotoKit limit or
// an inefficiency of mine? It separates the phases and compares extraction strategies, over
// the same assets, so that the number that ends up in the plan is a fact and not an artefact.

import AppKit
import Photos
import CoreImage

let SAMPLE = 100

func timed(_ name: String, _ n: Int, _ block: () -> Int) {
    let t0 = Date()
    let succeeded = block()
    let dt = Date().timeIntervalSince(t0)
    let perSec = dt > 0 ? Double(succeeded) / dt : 0
    let estimate = perSec > 0 ? 54169.0 / perSec / 60 : 0
    say(String(format: "BENCH %@  %d ok in %.2fs  →  %.1f photos/s  (whole library: %.1f min)",
               name.padding(toLength: 34, withPad: " ", startingAt: 0), succeeded, dt, perSec, estimate))
}

func runBenchmark() {
    let fetchOptions = PHFetchOptions()
    fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let result = PHAsset.fetchAssets(with: fetchOptions)
    let n = min(SAMPLE, result.count)
    var assets: [PHAsset] = []
    for i in 0..<n { assets.append(result.object(at: i)) }

    say("BENCH ===== sample of \(n) assets, library of \(result.count) =====")

    let manager = PHImageManager.default()

    func options(_ delivery: PHImageRequestOptionsDeliveryMode,
                 _ resize: PHImageRequestOptionsResizeMode) -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.isNetworkAccessAllowed = false
        o.deliveryMode = delivery
        o.resizeMode = resize
        return o
    }

    // --- 1. extraction only, various options -------------------------------------------
    func extractionOnly(_ size: CGSize, _ o: PHImageRequestOptions) -> Int {
        var ok = 0
        for a in assets {
            manager.requestImage(for: a, targetSize: size, contentMode: .aspectFill, options: o) { img, _ in
                if img != nil { ok += 1 }
            }
        }
        return ok
    }

    timed("extraction 512x288 highQuality/exact", n) { extractionOnly(CGSize(width: 512, height: 288), options(.highQualityFormat, .exact)) }
    timed("extraction 512x288 fastFormat/fast",   n) { extractionOnly(CGSize(width: 512, height: 288), options(.fastFormat, .fast)) }
    timed("extraction 256x144 highQuality/exact", n) { extractionOnly(CGSize(width: 256, height: 144), options(.highQualityFormat, .exact)) }
    timed("extraction 128x72  fastFormat/fast",   n) { extractionOnly(CGSize(width: 128, height: 72),  options(.fastFormat, .fast)) }

    // --- 2. via the original data + embedded thumbnail -----------------------------------
    timed("original data + CGImageSource", n) {
        var ok = 0
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.isNetworkAccessAllowed = false
        for a in assets {
            manager.requestImageDataAndOrientation(for: a, options: o) { data, _, _, _ in
                guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) != nil { ok += 1 }
            }
        }
        return ok
    }

    // --- 3. the cost of post-processing, on identical images -----------------------------
    var sample: [NSImage] = []
    let o = options(.highQualityFormat, .exact)
    for a in assets.prefix(50) {
        manager.requestImage(for: a, targetSize: CGSize(width: 512, height: 288),
                             contentMode: .aspectFill, options: o) { img, _ in
            if let img { sample.append(img) }
        }
    }
    say("BENCH ----- post-processing over \(sample.count) images already in memory -----")

    timed("JPEG encode (without writing)", sample.count) {
        var ok = 0
        for img in sample {
            if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
               r.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) != nil { ok += 1 }
        }
        return ok
    }

    timed("average colour, a NEW CIContext every time", sample.count) {
        var ok = 0
        for img in sample {
            guard let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                  let ci = CIImage(bitmapImageRep: r) else { continue }
            if averageColour(ci, CIContext(options: [.workingColorSpace: NSNull()])) != nil { ok += 1 }
        }
        return ok
    }

    let sharedContext = CIContext(options: [.workingColorSpace: NSNull()])
    timed("average colour, SHARED CIContext", sample.count) {
        var ok = 0
        for img in sample {
            guard let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                  let ci = CIImage(bitmapImageRep: r) else { continue }
            if averageColour(ci, sharedContext) != nil { ok += 1 }
        }
        return ok
    }

    say("BENCH done")
}

func averageColour(_ ci: CIImage, _ ctx: CIContext) -> (Double, Double, Double)? {
    guard let out = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent),
    ])?.outputImage else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
}
