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
        for text in ["", "v", "0..4", "0.4.", "0.4b", "+1", "v-1", "0.4 beta", "V0.4"] {
            #expect(ReleaseVersion(text) == nil, "\(text)")
        }
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
