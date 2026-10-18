import Foundation
import MosaicCore
import MosaicPhotos
import SQLite3
import Testing
@testable import MosaicPhotoKit

/// `PhotosDatabase` against small databases shaped like Photos', made here.
@Suite("Photos database")
struct PhotosDatabaseTests {
    /// One photograph of the fake library: its UUID, score, failure score and
    /// whether it is a screenshot.
    struct Row {
        var uuid: String
        var score: Double?
        var failure: Double?
        var screenshot = false
    }

    /// A database at a new path, with the columns asked for. `open` keeps the
    /// writing connection open and returns it, so its log is not checkpointed.
    @discardableResult
    private func database(
        _ rows: [Row], screenshots: Bool = true, computed: Bool = true, wal: Bool = false, keepOpen: Bool = false,
        at url: URL
    ) throws -> OpaquePointer? {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        func exec(_ sql: String) throws {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            try #require(rc == SQLITE_OK, "\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
        if wal { try exec("pragma journal_mode=wal; pragma wal_autocheckpoint=0") }
        try exec("create table ZASSET (Z_PK integer primary key, ZUUID varchar, ZOVERALLAESTHETICSCORE float\(screenshots ? ", ZISDETECTEDSCREENSHOT integer" : ""))")
        if computed { try exec("create table ZCOMPUTEDASSETATTRIBUTES (Z_PK integer primary key, ZASSET integer, ZFAILURESCORE float)") }
        func value(_ number: Double?) -> String { number.map { "\($0)" } ?? "null" }
        for (index, row) in rows.enumerated() {
            try exec("insert into ZASSET values (\(index + 1), '\(row.uuid)', \(value(row.score))\(screenshots ? ", \(row.screenshot ? 1 : 0)" : ""))")
            if computed { try exec("insert into ZCOMPUTEDASSETATTRIBUTES values (\(index + 1), \(index + 1), \(value(row.failure)))") }
        }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photos-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Photos.sqlite")
    }

    private func id(_ uuid: String) -> PhotoID { PhotoID("\(uuid)/L0/001") }

    private func reading(_ outcome: PhotosDatabase.Outcome) throws -> PhotosDatabase.Reading {
        guard case .read(let reading) = outcome else {
            Issue.record("refused: \(outcome)")
            throw CancellationError()
        }
        return reading
    }

    @Test("the placeholder is 0.5 with no failure score; 0 and a real 0.5 are scores")
    func placeholder() throws {
        let url = temporaryFile()
        try database([
            Row(uuid: "A", score: 0.5, failure: 0),
            Row(uuid: "B", score: 0.5, failure: nil),
            Row(uuid: "C", score: 0.5, failure: -0.01),
            Row(uuid: "D", score: 0, failure: -0.07),
            Row(uuid: "E", score: 0.73, failure: 0),
            Row(uuid: "F", score: nil, failure: -0.01),
            Row(uuid: "G", score: 1.7, failure: -0.01),
        ], at: url)
        let ids = ["A", "B", "C", "D", "E", "F", "G"].map(id)
        let reading = try reading(PhotosDatabase.read(at: url, ids: ids))
        #expect(reading.matched == 7)
        #expect(reading.placeholders == 2)
        #expect(reading.qualities[id("A")]?.score == nil)
        #expect(reading.qualities[id("B")]?.score == nil)
        #expect(reading.qualities[id("C")]?.score == 0.5)
        #expect(reading.qualities[id("D")]?.score == 0)
        #expect(reading.qualities[id("E")]?.score == 0.73)
        #expect(reading.qualities[id("F")]?.score == nil)
        #expect(reading.qualities[id("G")]?.score == nil, "out of 0…1 is not a score")
        #expect(reading.scored == 3)
        #expect(reading.missing.isEmpty)
    }

    @Test("screenshots are read, and only the identifiers asked about")
    func screenshots() throws {
        let url = temporaryFile()
        try database([
            Row(uuid: "A", score: 0.4, failure: -0.01, screenshot: true),
            Row(uuid: "B", score: 0.6, failure: -0.01),
            Row(uuid: "Z", score: 0.6, failure: -0.01, screenshot: true),
        ], at: url)
        let reading = try reading(PhotosDatabase.read(at: url, ids: [id("A"), id("B")]))
        #expect(reading.qualities.count == 2)
        #expect(reading.qualities[id("A")]?.isScreenshot == true)
        #expect(reading.qualities[id("B")]?.isScreenshot == false)
        #expect(reading.screenshots == 1)
    }

    @Test("without the screenshot column the scores still come, said as missing")
    func noScreenshotColumn() throws {
        let url = temporaryFile()
        try database([Row(uuid: "A", score: 0.4, failure: -0.01)], screenshots: false, at: url)
        let reading = try reading(PhotosDatabase.read(at: url, ids: [id("A")]))
        #expect(reading.qualities[id("A")] == PhotoQuality(score: 0.4, isScreenshot: false))
        #expect(reading.missing == ["ZASSET.ZISDETECTEDSCREENSHOT"])
    }

    @Test("without failure scores an exact 0.5 counts as none")
    func noFailureColumn() throws {
        let url = temporaryFile()
        try database([Row(uuid: "A", score: 0.5), Row(uuid: "B", score: 0.41)], computed: false, at: url)
        let reading = try reading(PhotosDatabase.read(at: url, ids: [id("A"), id("B")]))
        #expect(reading.qualities[id("A")]?.score == nil)
        #expect(reading.qualities[id("B")]?.score == 0.41)
        #expect(reading.missing == ["ZCOMPUTEDASSETATTRIBUTES.ZFAILURESCORE"])
    }

    @Test("another library, a missing table or column, or no database at all, is refused")
    func refusals() throws {
        let url = temporaryFile()
        try database((0..<100).map { Row(uuid: "U\($0)", score: 0.5, failure: -0.01) }, at: url)
        // 94 of 100: not this library.
        let mostly = (0..<94).map { id("U\($0)") } + (0..<6).map { id("X\($0)") }
        guard case .refused = PhotosDatabase.read(at: url, ids: mostly) else {
            Issue.record("a library missing 6 % of the photographs was accepted")
            return
        }
        #expect((try? reading(PhotosDatabase.read(at: url, ids: Array(mostly.prefix(95))))) != nil)

        var db: OpaquePointer?
        let empty = temporaryFile()
        sqlite3_open(empty.path, &db)
        sqlite3_exec(db, "create table ZASSET (Z_PK integer primary key, ZUUID varchar)", nil, nil, nil)
        sqlite3_close(db)
        guard case .refused(let noScore) = PhotosDatabase.read(at: empty, ids: [id("A")]) else {
            Issue.record("a database without scores was accepted")
            return
        }
        #expect(noScore.contains("ZOVERALLAESTHETICSCORE"))

        let notSQLite = temporaryFile()
        try Data("not a database".utf8).write(to: notSQLite)
        guard case .refused = PhotosDatabase.read(at: notSQLite, ids: [id("A")]) else {
            Issue.record("a text file was read as a database")
            return
        }
        guard case .refused = PhotosDatabase.read(at: temporaryFile(), ids: [id("A")]) else {
            Issue.record("a missing file was read as a database")
            return
        }
    }

    @Test("a live write-ahead log is read, as photolibraryd leaves it")
    func writeAheadLog() throws {
        let url = temporaryFile()
        let writer = try database(
            [Row(uuid: "A", score: 0.25, failure: -0.01)], wal: true, keepOpen: true, at: url
        )
        defer { sqlite3_close(writer) }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let reading = try reading(PhotosDatabase.read(at: url, ids: [id("A")]))
        #expect(reading.qualities[id("A")]?.score == 0.25)
    }

    @Test("the source tries each library in turn, and asks nothing without full access")
    func source() throws {
        // Two libraries shaped as `PhotosLibraryLocator.database(in:)` expects:
        // a stale one first, then the one PhotoKit reads.
        let libraries = (0..<2).map { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).photoslibrary")
        }
        for library in libraries {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent("database"), withIntermediateDirectories: true
            )
        }
        try database([Row(uuid: "OLD", score: 0.4, failure: -0.01)], at: PhotosLibraryLocator.database(in: libraries[0]))
        try database([Row(uuid: "A", score: 0.4, failure: -0.01)], at: PhotosLibraryLocator.database(in: libraries[1]))
        let photos = [PhotoDescriptor(id: id("A"), versionToken: "1")]
        let source = PhotosDatabaseQualitySource(candidates: { libraries }, isAuthorized: { true })
        #expect(source.qualities(of: photos)[id("A")]?.score == 0.4)

        let refused = PhotosDatabaseQualitySource(candidates: {
            Issue.record("looked for the library without full access")
            return libraries
        }, isAuthorized: { false })
        #expect(refused.qualities(of: photos).isEmpty)
    }
}
