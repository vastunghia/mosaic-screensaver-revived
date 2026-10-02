import CryptoKit
import Foundation
import MosaicCore

/// One photograph, as the index remembers it.
///
/// Everything here is either an opaque token or a number. There is deliberately
/// no path built out of an identifier: the original screen saver's database
/// broke on `%`, `$`, `#` and `@` in file names (SPEC § 5), and the cure is that
/// identifiers never become paths at all.
public struct IndexEntry: Codable, Equatable, Sendable {
    public let id: String
    public let versionToken: String

    /// Where the thumbnail lives, relative to the index directory. It is a hash
    /// of `(id, versionToken)`, so it is a pure function of this entry.
    public let thumbnail: String

    public let signatureSide: Int

    /// `side² × 3` linear-light components, 32-bit floats, little endian.
    ///
    /// Not an array of numbers in the JSON: a 4x4 signature is 48 components,
    /// and spelling those out decimally costs about a kilobyte per photograph
    /// for something no one reads. Base64 of the raw floats is exact and about
    /// a fifth of the size.
    public let signature: Data

    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Where the 16:9 window sits in the whole photograph, as
    /// `CanonicalCrop.rect(width:height:start:)` takes it; absent when it is
    /// centred. Chosen once, here, by `FaceAwareCrop` (SPEC § 4), so that the
    /// thumbnail, the signature, the target and every full-resolution close-up
    /// are cut from the same place — a crossfade between two windows would jump.
    public let cropStart: Double?

    public init(
        id: String,
        versionToken: String,
        thumbnail: String,
        signature: TileSignature,
        pixelWidth: Int,
        pixelHeight: Int,
        cropStart: Double? = nil
    ) {
        self.id = id
        self.versionToken = versionToken
        self.thumbnail = thumbnail
        self.signatureSide = signature.side
        self.signature = Self.encode(signature)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cropStart = cropStart
    }

    public var photoID: PhotoID { PhotoID(id) }

    /// The stored signature, or nil if the bytes do not match the declared side.
    public var tileSignature: TileSignature? {
        let expected = signatureSide * signatureSide * 3
        guard signatureSide >= 1, signature.count == expected * MemoryLayout<Float>.size else {
            return nil
        }
        var components = [Float](repeating: 0, count: expected)
        _ = components.withUnsafeMutableBytes { signature.copyBytes(to: $0) }

        var cells: [LinearRGB] = []
        cells.reserveCapacity(signatureSide * signatureSide)
        for index in 0..<(signatureSide * signatureSide) {
            cells.append(LinearRGB(
                r: Double(components[index * 3]),
                g: Double(components[index * 3 + 1]),
                b: Double(components[index * 3 + 2])
            ))
        }
        return TileSignature(side: signatureSide, cells: cells)
    }

    private static func encode(_ signature: TileSignature) -> Data {
        var components: [Float] = []
        components.reserveCapacity(signature.cells.count * 3)
        for cell in signature.cells {
            components.append(Float(cell.r))
            components.append(Float(cell.g))
            components.append(Float(cell.b))
        }
        return components.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The thumbnail's name: a truncated SHA-256 of the entry's identity, fanned
    /// out one level so a directory never holds tens of thousands of files.
    ///
    /// Sequence numbers were the spike's answer and they are wrong for an index
    /// that changes: after a deletion a reused number binds old pixels to a new
    /// identifier, and a crash between writing the JPEG and writing the manifest
    /// leaves a thumbnail claiming to be something it is not. A name derived from
    /// the entry makes both impossible, and turns collecting orphans into a set
    /// difference.
    public static func thumbnailName(id: String, versionToken: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(id.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(versionToken.utf8))
        let hex = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        return "thumbs/\(hex.prefix(2))/\(hex).jpg"
    }
}

/// How an index chose its windows. Part of what makes an index reusable: one
/// built with another rule has thumbnails cut from other places.
///
/// The raw value is versioned on purpose. Changing `FaceAwareCrop` — the
/// headroom, the tie-breaks — moves windows, so it must come with a new value
/// here, or an old index would go on serving the old windows as if current.
public enum CropRule: String, Codable, Sendable, CaseIterable {
    /// Every window centred: the crop before faces were looked for.
    case centre
    /// `FaceAwareCrop` on Vision's faces, revision 3: headroom 0.5, area before
    /// distance, faces cut by the photograph's frame not counted.
    case faces = "faces-1"

    public static let standard = CropRule.faces
}

/// The index, as one file.
public struct IndexManifest: Codable, Equatable, Sendable {
    /// Bumped whenever anything above changes shape. A mismatch rebuilds; it
    /// never crashes and never half-reads.
    ///
    /// 2: `cropRule` and `IndexEntry.cropStart`, the face-aware crop (2026-10-02).
    public static let currentFormatVersion = 2

    public var formatVersion: Int

    /// The resolved folder these identifiers are relative to — or, for a source
    /// whose identifiers are global, the name of that source (`photos-library`).
    ///
    /// Identifiers are paths relative to a root, which makes them portable — and
    /// means two different folders with the same internal shape produce the same
    /// identifiers. Since the index directory is chosen separately from the photo
    /// folder, nothing else would stop one index from serving another folder's
    /// photographs. This is what stops it.
    public var root: String

    public var thumbnailWidth: Int
    public var thumbnailHeight: Int
    public var signatureSide: Int
    public var cropRule: CropRule

    /// Sorted by identifier, so two builds over the same folder produce a
    /// byte-identical manifest and idempotence is a free test.
    public var entries: [IndexEntry]

    /// Files that looked like images and would not decode. Kept so they are not
    /// retried on every run, and so a caller can say how many there were.
    public var skipped: [String]

    /// Photographs whose pixels were not on this Mac — iCloud, with downloads
    /// off. Unlike `skipped` these are asked for again on every build, because
    /// the answer changes when the user allows downloads; they are written down
    /// only so a caller can say how many are missing and why.
    ///
    /// Added after the first format, and read with a default rather than by
    /// bumping `formatVersion`: an older manifest simply had none, and a bump
    /// would throw away an index that is still exactly right.
    public var unavailable: [String]

    public init(
        formatVersion: Int = IndexManifest.currentFormatVersion,
        root: String,
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        signatureSide: Int,
        cropRule: CropRule = .standard,
        entries: [IndexEntry] = [],
        skipped: [String] = [],
        unavailable: [String] = []
    ) {
        self.formatVersion = formatVersion
        self.root = root
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.signatureSide = signatureSide
        self.cropRule = cropRule
        self.entries = entries
        self.skipped = skipped
        self.unavailable = unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, root, thumbnailWidth, thumbnailHeight, signatureSide, cropRule
        case entries, skipped, unavailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        root = try container.decode(String.self, forKey: .root)
        thumbnailWidth = try container.decode(Int.self, forKey: .thumbnailWidth)
        thumbnailHeight = try container.decode(Int.self, forKey: .thumbnailHeight)
        signatureSide = try container.decode(Int.self, forKey: .signatureSide)
        // Absent before format 2, which `matches` turns away anyway; read as
        // centred so an old manifest still decodes and is rebuilt, not thrown at.
        cropRule = try container.decodeIfPresent(CropRule.self, forKey: .cropRule) ?? .centre
        entries = try container.decode([IndexEntry].self, forKey: .entries)
        skipped = try container.decode([String].self, forKey: .skipped)
        unavailable = try container.decodeIfPresent([String].self, forKey: .unavailable) ?? []
    }

    /// Whether an index on disk can be continued rather than rebuilt.
    public func matches(
        root: String, thumbnailWidth: Int, signatureSide: Int, cropRule: CropRule = .standard
    ) -> Bool {
        formatVersion == Self.currentFormatVersion
            && self.cropRule == cropRule
            && self.root == root
            && self.thumbnailWidth == thumbnailWidth
            && self.signatureSide == signatureSide
    }
}
