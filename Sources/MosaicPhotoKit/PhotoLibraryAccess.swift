import Foundation
import Photos

/// Permission to read the library, and what there is to choose from in it.
public enum PhotoLibraryAccess {
    /// The four states a host has to handle, flattened from PhotoKit's.
    public enum Status: Equatable, Sendable {
        /// Never asked. The only state in which asking shows a prompt.
        case notDetermined
        case authorized
        /// Only the photographs the user picked. Indexed as they are; the host
        /// should say so, since the mosaics will draw on a fraction of the library.
        case limited
        /// Refused, or not the user's to give (parental controls, MDM). Only
        /// System Settings can change it.
        case denied
        case restricted
    }

    public static var status: Status {
        Status(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Asks, if asking is still possible, and returns the outcome.
    ///
    /// TCC attributes the request to the *responsible* process: run from a
    /// terminal, the prompt names the terminal and the grant goes to it. The app
    /// has to be launched as an app (`open Mosaic.app`) for the grant to be its own.
    public static func request() async -> Status {
        Status(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    public struct Album: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let count: Int
    }

    /// The albums a user can pick as the scope: Favorites first, then their own
    /// albums by title. Shared albums are left out — their photographs are
    /// rarely on this Mac.
    public static func albums() -> [Album] {
        var found: [Album] = []
        let images = PHFetchOptions()
        images.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        func add(_ collection: PHAssetCollection) {
            let count = PHAsset.fetchAssets(in: collection, options: images).count
            found.append(Album(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                count: count
            ))
        }

        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { collection, _, _ in add(collection) }

        var own: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in own.append(collection) }
        own.sort {
            ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending
        }
        own.forEach(add)
        return found
    }
}

extension PhotoLibraryAccess.Status {
    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}
