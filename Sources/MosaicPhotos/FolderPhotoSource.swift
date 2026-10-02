import CoreGraphics
import Foundation
import MosaicCore
import UniformTypeIdentifiers

/// Photographs in a folder on disk.
///
/// Useful in development and legitimate in production as an alternative to the
/// Photos library — and, for milestone 2, the folder the user points at *is* the
/// subset question of SPEC § 8.6, answered by hand.
public struct FolderPhotoSource: PhotoSource {
    /// The folder, resolved once. Symbolic links and `/var` against
    /// `/private/var` are settled here and never thought about again.
    public let root: URL

    private let descriptors: [PhotoDescriptor]
    private let urls: [PhotoID: URL]

    /// Files that look like images but could not be read. They are kept rather
    /// than dropped so a caller can say how many, instead of silently indexing
    /// fewer photographs than the folder holds.
    public let unreadable: [PhotoID]

    public init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = resolved

        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw PhotoSourceError.couldNotReadFolder(resolved)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .contentTypeKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let wanted = Set(keys)
        let manager = FileManager.default

        // The walk carries the relative path down with it instead of working it
        // out afterwards by subtracting the root's path from a file's.
        //
        // That arithmetic is unsound, and not in a way that shows up in one
        // place: `resolvingSymlinksInPath` rewrites /private/var to /var, a
        // directory enumerator hands back /private/var for the same files, and
        // `standardizedFileURL` rewrites in whichever direction — but only for
        // paths that exist. Two spellings of one directory, changing under you.
        var pending: [(url: URL, prefix: String)] = [(resolved, "")]
        var found: [PhotoDescriptor] = []
        var map: [PhotoID: URL] = [:]

        while let (directory, prefix) = pending.popLast() {
            let children = (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                let name = child.lastPathComponent
                // AppleDouble sidecars. They come back from any volume the files
                // have crossed that is not a Mac one, they resolve to JPEG by
                // extension, and they never decode.
                if name.hasPrefix("._") { continue }

                guard let values = try? child.resourceValues(forKeys: wanted) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name

                if values.isDirectory == true {
                    // Packages are opaque — a .photoslibrary is not a folder of
                    // photographs — and a symbolic link to a directory is not
                    // followed, because a cycle would never end.
                    if values.isPackage == true || values.isSymbolicLink == true { continue }
                    pending.append((child, relative))
                    continue
                }

                guard values.isRegularFile == true,
                      values.contentType?.conforms(to: .image) == true
                else { continue }

                let id = PhotoID(relative)
                guard map[id] == nil else { continue }

                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values.fileSize ?? 0
                found.append(PhotoDescriptor(
                    id: id,
                    versionToken: "\(modified.bitPattern)-\(size)"
                ))
                map[id] = child
            }
        }

        // A stable order, so two runs over the same folder build the same pool
        // and therefore the same mosaics.
        found.sort { $0.id.rawValue < $1.id.rawValue }

        self.descriptors = found
        self.urls = map
        self.unreadable = []
    }

    public func photos() throws -> [PhotoDescriptor] {
        descriptors
    }

    public func canonicalImage(for id: PhotoID, maxPixelWidth: Int) throws -> CGImage {
        // The identifier is looked up, never taken apart. The original screen
        // saver broke on `%`, `$`, `#` and `@` in file names (SPEC § 5) because
        // something along the way treated an identifier as a path to parse.
        guard let url = urls[id] else {
            throw PhotoSourceError.unknownPhoto(id)
        }
        do {
            return try CanonicalCrop.image(at: url, maxPixelWidth: maxPixelWidth)
        } catch {
            throw PhotoSourceError.couldNotRender(id)
        }
    }

    public func uprightImage(for id: PhotoID, cropWidth: Int) throws -> CGImage {
        guard let url = urls[id] else {
            throw PhotoSourceError.unknownPhoto(id)
        }
        do {
            return try CanonicalCrop.uprightImage(at: url, cropWidth: cropWidth)
        } catch {
            throw PhotoSourceError.couldNotRender(id)
        }
    }

    /// Where a photograph came from. Only an indexer needs this; nothing
    /// downstream of the index does.
    public func url(for id: PhotoID) -> URL? {
        urls[id]
    }
}
