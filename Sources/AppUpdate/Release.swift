import Foundation

/// The newest release, as the app learns it from GitHub's `releases/latest`:
/// its version, its notes, and the disk image `scripts/release.sh` builds,
/// with the checksum next to it.
public struct Release: Equatable, Sendable {
    public let version: ReleaseVersion
    /// Markdown, as written on the release page.
    public let notes: String
    public let page: URL?
    public let diskImage: URL
    public let checksum: URL?

    public init(version: ReleaseVersion, notes: String, page: URL?, diskImage: URL, checksum: URL?) {
        self.version = version
        self.notes = notes
        self.page = page
        self.diskImage = diskImage
        self.checksum = checksum
    }

    /// The disk image `scripts/release.sh` names for a version.
    public static func diskImageName(app: String, version: ReleaseVersion) -> String {
        "\(app)-\(version).dmg"
    }

    /// Reads the JSON of `GET /repos/{owner}/{repo}/releases/latest`. The
    /// version is the tag's; the disk image is the asset named after it, so a
    /// release carrying other files (the README's video, once) still works.
    public init(gitHub data: Data, app: String) throws {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ReleaseError.unreadable(error.localizedDescription)
        }
        guard !release.draft, !release.prerelease else { throw ReleaseError.notPublished(release.tag_name) }
        guard let version = ReleaseVersion(release.tag_name) else { throw ReleaseError.badTag(release.tag_name) }

        let name = Self.diskImageName(app: app, version: version)
        let assets = Dictionary(release.assets.map { ($0.name, $0.browser_download_url) }, uniquingKeysWith: { a, _ in a })
        guard let diskImage = assets[name] else { throw ReleaseError.noDiskImage(name) }
        self.init(
            version: version,
            notes: release.body ?? "",
            page: release.html_url,
            diskImage: diskImage,
            checksum: assets[name + ".sha256"]
        )
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: URL?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        // A local feed written by hand may leave these out.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tag_name = try container.decode(String.self, forKey: .tag_name)
            html_url = try container.decodeIfPresent(URL.self, forKey: .html_url)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            assets = try container.decode([Asset].self, forKey: .assets)
        }

        enum CodingKeys: String, CodingKey {
            case tag_name, html_url, body, draft, prerelease, assets
        }
    }
}

public enum ReleaseError: LocalizedError, Equatable {
    case unreadable(String)
    case notPublished(String)
    case badTag(String)
    case noDiskImage(String)

    public var errorDescription: String? {
        switch self {
        // Localized by the app that shows them: Bundle.main is its bundle.
        case .unreadable(let reason):
            String(localized: "the release could not be read: \(reason)",
                   comment: "Update error, followed by the reason; lowercase, follows a colon")
        case .notPublished(let tag):
            String(localized: "release \(tag) is a draft or a pre-release",
                   comment: "Update error, with a release tag such as v0.6; lowercase, follows a colon")
        case .badTag(let tag):
            String(localized: "the release tag \(tag) is not a version",
                   comment: "Update error, with a release tag; lowercase, follows a colon")
        case .noDiskImage(let name):
            String(localized: "the release has no \(name)",
                   comment: "Update error, with the name of a missing .dmg file; lowercase, follows a colon")
        }
    }
}

/// The `.sha256` file next to a disk image, as `shasum -a 256` writes it:
/// the digest in hexadecimal, two spaces (or a space and an asterisk, in
/// binary mode), the file name.
public enum Checksum {
    /// The digest given for `fileName`, lowercased; nil if the file does not
    /// name it.
    public static func sha256(in text: String, for fileName: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let digest = parts[0].lowercased()
            var name = parts[1].drop { $0 == " " }
            if name.first == "*" { name = name.dropFirst() }
            if name == fileName, digest.count == 64, digest.allSatisfy(\.isHexDigit) {
                return digest
            }
        }
        return nil
    }
}
