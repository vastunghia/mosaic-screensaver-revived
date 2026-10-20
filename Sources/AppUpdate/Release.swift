import Foundation

/// The newest release, as the app learns it from GitHub's `releases/latest`
/// (or its list of releases, for a release candidate):
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

    /// Reads the JSON of `GET /repos/{owner}/{repo}/releases/latest`, one
    /// release, or of `GET /repos/{owner}/{repo}/releases`, a list, of which it
    /// takes the newest version. Drafts never count; pre-releases only for a
    /// release candidate, which follows the candidates after it as well as the
    /// final version. The version is the tag's; the disk image is the asset
    /// named after it, so a release carrying other files (the README's video,
    /// once) still works.
    public init(gitHub data: Data, app: String, includingPrereleases: Bool = false) throws {
        let decoder = JSONDecoder()
        let releases: [GitHubRelease]
        let isList: Bool
        if let list = try? decoder.decode([GitHubRelease].self, from: data) {
            releases = list
            isList = true
        } else {
            do {
                releases = [try decoder.decode(GitHubRelease.self, from: data)]
            } catch {
                throw ReleaseError.unreadable(error.localizedDescription)
            }
            isList = false
        }

        let published = releases.filter { !$0.draft && (includingPrereleases || !$0.prerelease) }
        if !isList, published.isEmpty { throw ReleaseError.notPublished(releases[0].tag_name) }
        // In a list, a tag that is not a version is someone else's business.
        let versioned = published.compactMap { release in ReleaseVersion(release.tag_name).map { (release, $0) } }
        if !isList, versioned.isEmpty { throw ReleaseError.badTag(releases[0].tag_name) }
        guard let (release, version) = versioned.max(by: { $0.1 < $1.1 }) else { throw ReleaseError.noRelease }

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
    case noRelease

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
        case .noRelease:
            String(localized: "no release was found", comment: "Update error; lowercase, follows a colon")
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
