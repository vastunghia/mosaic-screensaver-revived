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
        /// Photographs and videos alike, as PhotoKit keeps it: only a guide to
        /// how big the album is.
        public let count: Int
    }

    /// Every album a user can pick, Favorites first, in the order of Photos'
    /// sidebar: what the harness looks titles up in.
    public static func albums() -> [Album] {
        albumTree().albums.map { Album(id: $0.id, title: $0.title, count: $0.count) }
    }

    /// The albums a user can pick as the scope, in the folders Photos shows
    /// them in: Favorites first, then the user's own folders and albums, in
    /// the order PhotoKit gives them. Shared albums are left out — their
    /// photographs are rarely on this Mac — and so are smart albums other than
    /// Favorites, and folders with nothing left in them.
    ///
    /// The counts are PhotoKit's `estimatedAssetCount`, which it keeps with the
    /// album. Counting only the images took a fetch per album: 143 s for the
    /// 2020 albums of a real library, measured 2026-09-30.
    public static func albumTree() -> AlbumTree {
        var roots: [AlbumTree.Node] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { collection, _, _ in
                roots.append(.favorites(id: collection.localIdentifier, title: title(of: collection), count: count(of: collection)))
            }
        roots += nodes(in: PHCollectionList.fetchTopLevelUserCollections(with: nil))
        return AlbumTree(roots: roots)
    }

    private static func nodes(in result: PHFetchResult<PHCollection>) -> [AlbumTree.Node] {
        var found: [AlbumTree.Node] = []
        result.enumerateObjects { collection, _, _ in
            if let folder = collection as? PHCollectionList {
                let children = nodes(in: PHCollection.fetchCollections(in: folder, options: nil))
                if !children.isEmpty {
                    found.append(.folder(id: folder.localIdentifier, title: title(of: folder), children: children))
                }
            } else if let album = collection as? PHAssetCollection, isPickable(album) {
                found.append(.album(id: album.localIdentifier, title: title(of: album), count: count(of: album)))
            }
        }
        return found
    }

    /// The user's own albums: not shared, not smart.
    static func isPickable(_ album: PHAssetCollection) -> Bool {
        album.assetCollectionType == .album && album.assetCollectionSubtype == .albumRegular
    }

    private static func title(of collection: PHCollection) -> String {
        collection.localizedTitle ?? "Untitled"
    }

    private static func count(of album: PHAssetCollection) -> Int {
        let estimated = album.estimatedAssetCount
        guard estimated == NSNotFound else { return estimated }
        let images = PHFetchOptions()
        images.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(in: album, options: images).count
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
