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

    public init(
        id: String,
        versionToken: String,
        thumbnail: String,
        signature: TileSignature,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.versionToken = versionToken
        self.thumbnail = thumbnail
        self.signatureSide = signature.side
        self.signature = Self.encode(signature)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
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

/// The index, as one file.
public struct IndexManifest: Codable, Equatable, Sendable {
    /// Bumped whenever anything above changes shape. A mismatch rebuilds; it
    /// never crashes and never half-reads.
    public static let currentFormatVersion = 1

    public var formatVersion: Int

    /// The resolved folder these identifiers are relative to.
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

    /// Sorted by identifier, so two builds over the same folder produce a
    /// byte-identical manifest and idempotence is a free test.
    public var entries: [IndexEntry]

    /// Files that looked like images and would not decode. Kept so they are not
    /// retried on every run, and so a caller can say how many there were.
    public var skipped: [String]

    public init(
        formatVersion: Int = IndexManifest.currentFormatVersion,
        root: String,
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        signatureSide: Int,
        entries: [IndexEntry] = [],
        skipped: [String] = []
    ) {
        self.formatVersion = formatVersion
        self.root = root
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.signatureSide = signatureSide
        self.entries = entries
        self.skipped = skipped
    }

    /// Whether an index on disk can be continued rather than rebuilt.
    public func matches(root: String, thumbnailWidth: Int, signatureSide: Int) -> Bool {
        formatVersion == Self.currentFormatVersion
            && self.root == root
            && self.thumbnailWidth == thumbnailWidth
            && self.signatureSide == signatureSide
    }
}
