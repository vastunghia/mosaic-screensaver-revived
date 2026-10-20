import Foundation
import Testing
@testable import AppUpdate

/// A wrong answer here either offers an update that is not newer — a
/// downgrade, or the same version every day — or never offers one.
@Suite("Release version")
struct ReleaseVersionTests {
    @Test("tags and plain versions read the same")
    func reading() {
        #expect(ReleaseVersion("v0.4")?.components == [0, 4])
        #expect(ReleaseVersion("0.4.1")?.components == [0, 4, 1])
        #expect(ReleaseVersion(" v1.10 \n")?.components == [1, 10])
        for text in ["", "v", "0..4", "0.4.", "0.4b", "+1", "v-1", "0.4 beta", "V0.4",
                     "1.0-", "1.0-rc", "1.0-1", "1.0-RC1", "1.0--rc1", "1.0-rc1-x", "-rc1"] {
            #expect(ReleaseVersion(text) == nil, "\(text)")
        }
    }

    @Test("a release candidate's suffix")
    func candidate() throws {
        let version = try #require(ReleaseVersion("v1.0-rc2"))
        #expect(version.components == [1, 0])
        #expect(version.stage == "rc")
        #expect(version.stageNumber == 2)
        #expect(version.isPrerelease)
        #expect(version.description == "1.0-rc2")
        #expect(try #require(ReleaseVersion("1.0")).isPrerelease == false)
    }

    @Test("numbers compare as numbers, missing ones as zero")
    func ordering() throws {
        let v = { (text: String) throws -> ReleaseVersion in try #require(ReleaseVersion(text)) }
        #expect(try v("0.4") < v("0.5"))
        #expect(try v("0.9") < v("0.10"))
        #expect(try v("0.4") < v("0.4.1"))
        #expect(try v("0.4") == v("0.4.0"))
        #expect(try !(v("1.0") < v("0.99")))
        #expect(try v("v0.4").description == "0.4")
    }

    @Test("a candidate comes after the version before it and before the one it leads to")
    func candidateOrdering() throws {
        let v = { (text: String) throws -> ReleaseVersion in try #require(ReleaseVersion(text)) }
        let ordered = try ["0.9.1", "1.0-rc1", "1.0-rc2", "1.0-rc10", "1.0", "1.0.1-rc1", "1.0.1"].map(v)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
        }
        #expect(try v("1.0-rc1") == v("1.0.0-rc1"))
        #expect(try !(v("1.0") < v("1.0-rc9")))
    }
}

@Suite("Release from GitHub")
struct ReleaseTests {
    private func json(tag: String = "v0.5", assets: [String] = ["Mosaic-0.5.dmg", "Mosaic-0.5.dmg.sha256"],
                      extra: String = "") -> Data {
        let list = assets.map {
            #"{"name": "\#($0)", "browser_download_url": "https://example.com/download/\#($0)"}"#
        }.joined(separator: ",")
        return Data(#"""
        {"tag_name": "\#(tag)", "html_url": "https://example.com/releases/\#(tag)",
         "body": "Notes **here**", "draft": false, "prerelease": false, \#(extra)
         "assets": [\#(list)]}
        """#.utf8)
    }

    @Test("the disk image named after the tag, and its checksum")
    func reading() throws {
        let release = try Release(gitHub: json(), app: "Mosaic")
        #expect(release.version == ReleaseVersion("0.5"))
        #expect(release.notes == "Notes **here**")
        #expect(release.diskImage.lastPathComponent == "Mosaic-0.5.dmg")
        #expect(release.checksum?.lastPathComponent == "Mosaic-0.5.dmg.sha256")
        #expect(release.page?.absoluteString == "https://example.com/releases/v0.5")
    }

    @Test("other files beside it do not matter; a missing checksum is allowed")
    func otherAssets() throws {
        let release = try Release(gitHub: json(assets: ["Mosaic-loop.mp4", "Mosaic-0.5.dmg"]), app: "Mosaic")
        #expect(release.diskImage.lastPathComponent == "Mosaic-0.5.dmg")
        #expect(release.checksum == nil)
    }

    @Test("no disk image of this version, a bad tag, or garbage: refused")
    func refused() {
        #expect(throws: ReleaseError.noDiskImage("Mosaic-0.5.dmg")) {
            try Release(gitHub: json(assets: ["Mosaic-0.4.dmg"]), app: "Mosaic")
        }
        #expect(throws: ReleaseError.badTag("latest")) {
            try Release(gitHub: json(tag: "latest"), app: "Mosaic")
        }
        #expect(throws: ReleaseError.self) {
            try Release(gitHub: Data(#"{"message": "Not Found"}"#.utf8), app: "Mosaic")
        }
    }

    @Test("a hand-written feed may leave out what GitHub always sends")
    func minimal() throws {
        let data = Data(#"""
        {"tag_name": "v0.5", "assets": [{"name": "Mosaic-0.5.dmg", "browser_download_url": "http://127.0.0.1:8000/Mosaic-0.5.dmg"}]}
        """#.utf8)
        let release = try Release(gitHub: data, app: "Mosaic")
        #expect(release.notes == "")
        #expect(release.page == nil)
    }
}

@Suite("Release from GitHub's list")
struct ReleaseListTests {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> String {
        let name = "Mosaic-\(tag.dropFirst()).dmg"
        return #"""
        {"tag_name": "\#(tag)", "draft": \#(draft), "prerelease": \#(prerelease),
         "assets": [{"name": "\#(name)", "browser_download_url": "https://example.com/\#(name)"}]}
        """#
    }

    private func list(_ releases: String...) -> Data {
        Data(("[" + releases.joined(separator: ",") + "]").utf8)
    }

    @Test("a final version ignores candidates; a candidate follows both")
    func choosing() throws {
        let data = list(release("v1.0-rc2", prerelease: true), release("v1.0-rc1", prerelease: true), release("v0.9"))
        #expect(try Release(gitHub: data, app: "Mosaic").version == ReleaseVersion("0.9"))
        let candidate = try Release(gitHub: data, app: "Mosaic", includingPrereleases: true)
        #expect(candidate.version == ReleaseVersion("1.0-rc2"))
        #expect(candidate.diskImage.lastPathComponent == "Mosaic-1.0-rc2.dmg")

        let final = list(release("v1.0"), release("v1.0-rc2", prerelease: true))
        #expect(try Release(gitHub: final, app: "Mosaic", includingPrereleases: true).version == ReleaseVersion("1.0"))
    }

    @Test("drafts and tags that are not versions are passed over")
    func passedOver() throws {
        let data = list(release("v2.0", draft: true), release("vnext"), release("v1.0-rc1", prerelease: true))
        #expect(try Release(gitHub: data, app: "Mosaic", includingPrereleases: true).version == ReleaseVersion("1.0-rc1"))
    }

    @Test("nothing to offer: no release")
    func empty() {
        #expect(throws: ReleaseError.noRelease) { try Release(gitHub: list(), app: "Mosaic") }
        #expect(throws: ReleaseError.noRelease) {
            try Release(gitHub: list(release("v1.0-rc1", prerelease: true)), app: "Mosaic")
        }
    }

    @Test("a single pre-release, as releases/latest never sends, is refused to a final version")
    func single() throws {
        let data = Data(release("v1.0-rc1", prerelease: true).utf8)
        #expect(throws: ReleaseError.notPublished("v1.0-rc1")) { try Release(gitHub: data, app: "Mosaic") }
        #expect(try Release(gitHub: data, app: "Mosaic", includingPrereleases: true).version == ReleaseVersion("1.0-rc1"))
    }
}

@Suite("Checksum file")
struct ChecksumTests {
    private let digest = "0b85ec3ccace33a7ca6b94757ed0e10d0e91359ebe529c4a06f3789f626c2ae6"

    @Test("as shasum writes it, in text or binary mode")
    func reading() {
        #expect(Checksum.sha256(in: "\(digest)  Mosaic-0.4.dmg\n", for: "Mosaic-0.4.dmg") == digest)
        #expect(Checksum.sha256(in: "\(digest.uppercased()) *Mosaic-0.4.dmg", for: "Mosaic-0.4.dmg") == digest)
    }

    @Test("another file, or no digest, gives nothing")
    func refused() {
        #expect(Checksum.sha256(in: "\(digest)  Mosaic-0.3.dmg", for: "Mosaic-0.4.dmg") == nil)
        #expect(Checksum.sha256(in: "abc  Mosaic-0.4.dmg", for: "Mosaic-0.4.dmg") == nil)
        #expect(Checksum.sha256(in: "", for: "Mosaic-0.4.dmg") == nil)
    }
}
