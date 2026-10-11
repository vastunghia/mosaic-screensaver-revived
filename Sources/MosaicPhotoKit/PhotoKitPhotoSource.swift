import AppKit
import CoreGraphics
import Foundation
import MosaicCore
import MosaicPhotos
import Photos
import os

/// The Photos library, as a `PhotoSource`.
///
/// This is the one place in the project that touches PhotoKit, and it is a
/// target of its own for that reason: `MosaicPhotos` is linked by the saver too,
/// and the saver must never load `Photos` — it inherits the TCC identity of
/// `legacyScreenSaver`, where asking for the library is unreliable (PLAN.md,
/// platform constraints). Only the app links this.
///
/// Identifiers are `localIdentifier`s, which are global to the library. Unlike a
/// folder's relative paths they do not need a root to mean something, so the
/// index is keyed by `PhotoKitPhotoSource.indexRoot` alone and changing the
/// albums in scope reuses every photograph the two scopes share.
public final class PhotoKitPhotoSource: PhotoSource, @unchecked Sendable {
    /// Which part of the library. SPEC § 5: nothing chosen means the whole
    /// library, otherwise the union of the albums and folders chosen. A folder
    /// is read when the photographs are, so it brings whatever albums it holds
    /// by then, in its subfolders too.
    public enum Scope: Equatable, Sendable {
        case library
        case collections([String])
    }

    /// What goes in the manifest's `root`.
    public static let indexRoot = "photos-library"

    public let scope: Scope

    /// Whether a photograph kept only in iCloud may be downloaded to be indexed
    /// (SPEC § 5, the user's choice, off by default). When it may not, it comes
    /// back as `PhotoSourceError.unavailable`.
    public let allowsNetworkAccess: Bool

    private let manager = PHImageManager.default()

    // PHAsset is not Sendable, and `canonicalImage` is called from every core at
    // once. The map is written once by `photos()` and only read after, but a
    // lock is cheaper to reason about than that promise.
    private let lock = NSLock()
    private var assets: [String: PHAsset] = [:]

    public init(scope: Scope = .library, allowsNetworkAccess: Bool = false) {
        self.scope = scope
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    /// Every image in scope, sorted by identifier.
    ///
    /// PhotoKit's default fetch leaves out hidden photographs and all but the
    /// representative of each burst — which is what a mosaic wants, and half of
    /// SPEC § 8.8 answered for free.
    public func photos() throws -> [PhotoDescriptor] {
        var found: [String: PHAsset] = [:]
        for result in fetchResults() {
            result.enumerateObjects { asset, _, _ in
                found[asset.localIdentifier] = asset
            }
        }

        lock.lock()
        assets = found
        lock.unlock()

        return found.values
            .map { asset in
                PhotoDescriptor(
                    id: PhotoID(asset.localIdentifier),
                    versionToken: Self.versionToken(of: asset),
                    creationDate: asset.creationDate
                )
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        let image = try uprightImage(for: id, cropWidth: maxPixelWidth)
        // The same crop and sRGB redraw a folder's photographs go through, so
        // that the two sources owe the same postcondition by construction.
        do {
            return try CanonicalCrop.image(image, maxPixelWidth: maxPixelWidth)
        } catch {
            throw PhotoSourceError.couldNotRender(id)
        }
    }

    public func uprightImage(for id: PhotoID, cropWidth maxPixelWidth: Int) throws -> CGImage {
        precondition(maxPixelWidth > 0)
        guard let asset = asset(for: id) else { throw PhotoSourceError.unknownPhoto(id) }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        // Not `.fastFormat`: spike 3 found it returns a small ready-made
        // derivative whatever size is asked for, and never checked how small.
        options.deliveryMode = .highQualityFormat
        // Not `.exact`: without the original, `.exact` scales a smaller local
        // derivative up to the size asked for, and the result passes for the
        // real thing. On an optimised library (2026-10-11) about 108 of 257
        // thumbnails were 640 px derivatives scaled up to 854. `.fast` hands
        // back what PhotoKit has, at its own size, so a short one shows.
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.version = .current

        var delivered: NSImage?
        var inCloud = false
        var degraded = false
        // `.fast` comes back a little short of the size asked for even from a
        // local original: 850 for 855, 1914 for 1921 (measured 2026-10-11). So
        // it is asked for 5 % more, and `scaled` takes the excess off. But a
        // local derivative is only handed back when it is at least as large as
        // the request: one of 856 px gives nothing to a request of 897. So when
        // the larger request gives nothing, the exact one is tried too.
        var asked = CGSize.zero
        let started = Date()
        for cropWidth in [maxPixelWidth + (maxPixelWidth + 19) / 20, maxPixelWidth] {
            asked = Self.targetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, cropWidth: cropWidth)
            manager.requestImage(for: asset, targetSize: asked, contentMode: .aspectFill, options: options) { image, info in
                delivered = image
                inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            }
            if delivered != nil { break }
        }
        let image = delivered?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let needed = Self.neededCropWidth(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                          cropWidth: maxPixelWidth)
        let got = image.map { Int(CanonicalCrop.rect(width: $0.width, height: $0.height).width) }
        // One pixel short is PhotoKit's rounding (`targetSize`); more is a
        // derivative smaller than the photograph allows.
        let short = got.map { $0 < needed - 1 } ?? false
        logIfUnusual(id, asset: asset, asked: asked, got: image, short: short, inCloud: inCloud, degraded: degraded,
                     seconds: Date().timeIntervalSince(started))

        // With downloads off, nothing is always "not on this Mac": PhotoKit
        // leaves out `PHImageResultIsInCloudKey` now and then (19 times in one
        // optimised library) for a photograph it rendered at a smaller size.
        guard delivered != nil else {
            throw inCloud || !allowsNetworkAccess
                ? PhotoSourceError.unavailable(id)
                : PhotoSourceError.couldNotRender(id)
        }
        guard let image, let got else { throw PhotoSourceError.couldNotRender(id) }
        guard !short else { throw PhotoSourceError.unavailable(id) }
        guard got > maxPixelWidth + 1 else { return image }
        return try Self.scaled(image, by: Double(maxPixelWidth + 1) / Double(got), id: id)
    }

    /// The narrowest crop that is the photograph's own and not a smaller
    /// derivative: `cropWidth`, or less when the original is that small.
    ///
    /// PhotoKit reports 0×0 for some photographs of a library still coming
    /// down from iCloud (2026-10-11, a crash: `CanonicalCrop.rect` requires a
    /// size). Not knowing how large the original is, the whole width is asked.
    public static func neededCropWidth(pixelWidth: Int, pixelHeight: Int, cropWidth: Int) -> Int {
        guard pixelWidth > 0, pixelHeight > 0 else { return cropWidth }
        return min(cropWidth, Int(CanonicalCrop.rect(width: pixelWidth, height: pixelHeight).width))
    }

    /// `.fast` may hand back more than was asked for; the contract is a crop at
    /// most `cropWidth` across, and Vision's time grows with the pixels.
    private static func scaled(_ image: CGImage, by scale: Double, id: PhotoID) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * scale).rounded(.up)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.up)))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw PhotoSourceError.couldNotRender(id) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw PhotoSourceError.couldNotRender(id) }
        return result
    }

    /// One line in the unified log for every request that did not go the
    /// ordinary way: nothing delivered, a crop narrower than the photograph allows,
    /// flagged as in iCloud or degraded, or slow enough to be a download. None
    /// of these stops indexing, and each would otherwise pass unseen: a smaller
    /// derivative still makes a mosaic, only a softer one.
    private func logIfUnusual(
        _ id: PhotoID, asset: PHAsset, asked: CGSize, got: CGImage?, short: Bool, inCloud: Bool, degraded: Bool,
        seconds: Double
    ) {
        guard got == nil || short || inCloud || degraded || seconds > 1 else { return }
        let delivered = got.map { "\($0.width)x\($0.height)" } ?? "nothing"
        Self.log.notice("""
            request \(id.rawValue, privacy: .public): original \(asset.pixelWidth, privacy: .public)x\(asset.pixelHeight, privacy: .public), \
            asked \(Int(asked.width), privacy: .public)x\(Int(asked.height), privacy: .public), \
            got \(delivered, privacy: .public), in iCloud \(inCloud, privacy: .public), \
            degraded \(degraded, privacy: .public), network \(self.allowsNetworkAccess, privacy: .public), \
            \(Int(seconds * 1000), privacy: .public) ms
            """)
    }

    /// What this Mac holds of a photograph without asking iCloud, for
    /// `--probe-local`: whether the original's data is here, and the largest
    /// image PhotoKit will render from what is here.
    ///
    /// Not one request at `PHImageManagerMaximumSize`: without the original
    /// that gives nothing even when a derivative of 854 px is here (measured on
    /// an optimised library, 2026-10-11). So the request climbs `ladder`, crop
    /// widths, with `.fast`, which may hand back more than asked for: what comes
    /// back is the derivative's own size, not one scaled up to the request.
    public struct LocalAvailability: Sendable {
        public var originalBytes: Int?
        /// The largest crop width of the ladder that gave an image.
        public var largestCropWidth: Int?
        /// The largest image any step gave, at the size PhotoKit chose.
        public var largest: (width: Int, height: Int)?
        /// The first step that gave nothing said the photograph is in iCloud.
        public var inCloud: Bool
        public var seconds: Double
    }

    public static let ladder = [128, 256, 427, 640, 854, 1024, 1280, 1600, 1920, 2560, 3840]

    public func localAvailability(of id: PhotoID) throws -> LocalAvailability {
        guard let asset = asset(for: id) else { throw PhotoSourceError.unknownPhoto(id) }
        let started = Date()

        let dataOptions = PHImageRequestOptions()
        dataOptions.isSynchronous = true
        dataOptions.isNetworkAccessAllowed = false
        dataOptions.version = .original
        var bytes: Int?
        manager.requestImageDataAndOrientation(for: asset, options: dataOptions) { data, _, _, _ in
            bytes = data?.count
        }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.version = .current
        var probe = LocalAvailability(originalBytes: bytes, largestCropWidth: nil, largest: nil, inCloud: false, seconds: 0)
        var refused = false
        for cropWidth in Self.ladder {
            let asked = Self.targetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, cropWidth: cropWidth)
            var got: CGImage?
            var inCloud = false
            manager.requestImage(for: asset, targetSize: asked, contentMode: .aspectFill, options: options) { image, info in
                got = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            }
            guard let got else {
                if !refused { probe.inCloud = inCloud }
                refused = true
                continue
            }
            probe.largestCropWidth = cropWidth
            if got.width * got.height > (probe.largest.map { $0.width * $0.height } ?? 0) {
                probe.largest = (got.width, got.height)
            }
        }
        probe.seconds = Date().timeIntervalSince(started)
        return probe
    }

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "photokit")

    /// The size to ask PhotoKit for so that the **canonical crop** of what comes
    /// back is `cropWidth` across.
    ///
    /// Asking for `cropWidth × cropWidth·9/16` with `.aspectFill` would do on a
    /// landscape photograph and be soft on a portrait one, whose 16:9 crop is a
    /// band across the middle — the same trap `CanonicalCrop` documents for
    /// `kCGImageSourceThumbnailMaxPixelSize`. So the whole photograph is scaled
    /// by the factor that makes its crop the right width. Never upwards: a small
    /// photograph comes back at its own size.
    ///
    /// One pixel more than needed, because PhotoKit rounds down: asked for
    /// exactly enough, it delivered 853 of 854 and 232 of 233 (measured with
    /// `--verify-canonical`). The crop then trims the extra pixel.
    public static func targetSize(pixelWidth: Int, pixelHeight: Int, cropWidth: Int) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return CGSize(width: cropWidth, height: CanonicalAspect.height(forWidth: cropWidth))
        }
        let crop = CanonicalCrop.rect(width: pixelWidth, height: pixelHeight)
        let scale = min(1, Double(cropWidth + 1) / Double(crop.width))
        return CGSize(
            width: (Double(pixelWidth) * scale).rounded(.up),
            height: (Double(pixelHeight) * scale).rounded(.up)
        )
    }

    /// Changes whenever the photograph is edited. `modificationDate` also moves
    /// for changes that leave the pixels alone (a favourite, a keyword), which
    /// costs a needless re-read and nothing worse; the dimensions are in the
    /// token as well because a crop changes them.
    static func versionToken(of asset: PHAsset) -> String {
        let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(modified.bitPattern)-\(asset.pixelWidth)x\(asset.pixelHeight)"
    }

    /// The photograph's own size as PhotoKit reports it, for diagnostics: a
    /// canonical image narrower than asked is fine when this is small too.
    public func pixelSize(of id: PhotoID) -> (width: Int, height: Int)? {
        asset(for: id).map { ($0.pixelWidth, $0.pixelHeight) }
    }

    private func asset(for id: PhotoID) -> PHAsset? {
        lock.lock()
        let known = assets[id.rawValue]
        lock.unlock()
        if let known { return known }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject
    }

    private func fetchResults() -> [PHFetchResult<PHAsset>] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        switch scope {
        case .library:
            return [PHAsset.fetchAssets(with: options)]
        case .collections(let identifiers):
            return Self.albums(chosen: Set(identifiers)).map { PHAsset.fetchAssets(in: $0, options: options) }
        }
    }

    /// The albums a choice stands for, found by walking the sidebar's tree
    /// rather than fetched by identifier: an album's identifier handed to
    /// `PHCollectionList.fetchCollectionLists(withLocalIdentifiers:)` raises
    /// an Objective-C exception, and nothing public tells the two kinds
    /// apart. A chosen folder brings every album under it, at any depth.
    static func albums(chosen: Set<String>) -> [PHAssetCollection] {
        var found: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { album, _, _ in
                if chosen.contains(album.localIdentifier) { found.append(album) }
            }
        func walk(_ result: PHFetchResult<PHCollection>, inChosenFolder: Bool) {
            result.enumerateObjects { collection, _, _ in
                let isChosen = inChosenFolder || chosen.contains(collection.localIdentifier)
                if let folder = collection as? PHCollectionList {
                    walk(PHCollection.fetchCollections(in: folder, options: nil), inChosenFolder: isChosen)
                } else if isChosen, let album = collection as? PHAssetCollection, PhotoLibraryAccess.isPickable(album) {
                    found.append(album)
                }
            }
        }
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), inChosenFolder: false)
        return found
    }
}
