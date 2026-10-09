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
    /// album and which includes videos: `videoCounts()` gives what to take out.
    public static func albumTree() -> AlbumTree {
        var roots: [AlbumTree.Node] = []
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { collection, _, _ in
                roots.append(.favorites(id: collection.localIdentifier, title: title(of: collection), count: count(of: collection)))
            }
        roots += nodes(in: PHCollectionList.fetchTopLevelUserCollections(with: nil))
        return AlbumTree(roots: roots)
    }

    /// How many videos each album holds, Favorites included, by identifier.
    ///
    /// Asked the other way round, video by video, because a library has far
    /// fewer videos than its albums hold photographs. On a real library,
    /// measured 2026-10-09: 7.8 s for 4745 videos across 2019 albums, against
    /// 22.8 s counting each album's images (`countOfAssets(with:)`) and about
    /// 145 s fetching them with a predicate. Slow enough to run after the
    /// albums are listed, not before.
    public static func videoCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        var favorites = 0
        PHAsset.fetchAssets(with: .video, options: nil).enumerateObjects { video, _, _ in
            if video.isFavorite { favorites += 1 }
            PHAssetCollection.fetchAssetCollectionsContaining(video, with: .album, options: nil)
                .enumerateObjects { album, _, _ in counts[album.localIdentifier, default: 0] += 1 }
        }
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            .enumerateObjects { album, _, _ in counts[album.localIdentifier] = favorites }
        return counts
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
        // Videos included, like the estimate, so `videoCounts()` applies to both.
        return PHAsset.fetchAssets(in: album, options: nil).count
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
