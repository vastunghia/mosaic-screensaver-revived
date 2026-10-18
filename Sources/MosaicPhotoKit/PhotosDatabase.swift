import Foundation
import MosaicCore
import MosaicPhotos
import Photos
import SQLite3
import os

/// Photos' own verdict on its photographs, read from the library's database
/// (spike 5): the aesthetic score of the whole library before a subset is
/// chosen, for one query and no decoding, and which photographs are
/// screenshots.
///
/// The database is private and undocumented, so nothing here is trusted
/// without a check, and nothing fails: a table or column that is not there, a
/// file that will not open, a library whose identifiers are not PhotoKit's,
/// are all "no score", said once in the log. The photographs are then judged by
/// Vision as they are indexed.
public enum PhotosDatabase {
    public struct Reading: Sendable {
        /// For the identifiers asked about that the database has.
        public var qualities: [PhotoID: PhotoQuality]
        public var matched: Int
        public var scored: Int
        /// Not analysed by Photos yet: score exactly 0.5 and no failure score.
        public var placeholders: Int
        public var screenshots: Int
        /// The optional columns the database did not have.
        public var missing: [String]
    }

    public enum Outcome: Sendable {
        case read(Reading)
        case refused(String)
    }

    /// What Photos writes for a photograph it has not analysed, with a failure
    /// score of 0 or none. 0.5 is also a real score, so it is the pair that
    /// tells; the curation score is 0 on one Mac and 0.5 on another, and is
    /// not looked at.
    public static let placeholderScore = 0.5

    /// Of the identifiers asked about, the share a database must have to be
    /// the library PhotoKit reads. A stale library beside the real one has
    /// none of them.
    public static let minimumMatch = 0.95

    /// Reads `database` read only, for the photographs `ids`.
    ///
    /// `mode=ro`, so that the live write-ahead log of `photolibraryd` is read
    /// too; never `immutable=1`, which ignores it. Waits two seconds at most
    /// for a lock.
    public static func read(at database: URL, ids: [PhotoID], minimumMatch: Double = Self.minimumMatch) -> Outcome {
        let path = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return .refused("cannot open \(database.path): \(message(db))")
        }
        sqlite3_busy_timeout(db, 2000)

        let asset = columns(of: "ZASSET", in: db)
        let required = ["Z_PK", "ZUUID", "ZOVERALLAESTHETICSCORE"]
        let absent = required.filter { !asset.contains($0) }
        guard absent.isEmpty else {
            return .refused(asset.isEmpty
                ? "no ZASSET table in \(database.path): \(message(db))"
                : "ZASSET has no \(absent.joined(separator: ", "))")
        }
        let computed = columns(of: "ZCOMPUTEDASSETATTRIBUTES", in: db)
        let hasScreenshots = asset.contains("ZISDETECTEDSCREENSHOT")
        let hasFailure = computed.contains("ZASSET") && computed.contains("ZFAILURESCORE")
        var missing: [String] = []
        if !hasScreenshots { missing.append("ZASSET.ZISDETECTEDSCREENSHOT") }
        if !hasFailure { missing.append("ZCOMPUTEDASSETATTRIBUTES.ZFAILURESCORE") }

        let sql = """
            select a.ZUUID, a.ZOVERALLAESTHETICSCORE, \(hasScreenshots ? "a.ZISDETECTEDSCREENSHOT" : "0"), \
            \(hasFailure ? "c.ZFAILURESCORE" : "null") from ZASSET a\
            \(hasFailure ? " left join ZCOMPUTEDASSETATTRIBUTES c on c.ZASSET = a.Z_PK" : "")
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return .refused("cannot query \(database.path): \(message(db))")
        }

        // Every identifier, by the UUID the database knows it by.
        var wanted: [String: PhotoID] = [:]
        for id in ids { wanted[uuid(of: id)] = id }

        var reading = Reading(qualities: [:], matched: 0, scored: 0, placeholders: 0, screenshots: 0, missing: missing)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let text = sqlite3_column_text(statement, 0),
                  let id = wanted[String(cString: text)], reading.qualities[id] == nil else { continue }
            let isScreenshot = sqlite3_column_int(statement, 2) != 0
            let failure = double(statement, 3)
            var score = double(statement, 1)
            if score == placeholderScore, failure == nil || failure == 0 {
                score = nil
                reading.placeholders += 1
            }
            if let value = score, !(0...1).contains(value) { score = nil }
            reading.qualities[id] = PhotoQuality(score: score, isScreenshot: isScreenshot)
            reading.matched += 1
            if score != nil { reading.scored += 1 }
            if isScreenshot { reading.screenshots += 1 }
        }
        guard step == SQLITE_DONE else {
            return .refused("reading \(database.path) stopped: \(message(db))")
        }
        guard !ids.isEmpty, Double(reading.matched) >= Double(ids.count) * minimumMatch else {
            return .refused("\(database.path) has \(reading.matched) of \(ids.count) photographs: another library")
        }
        return .read(reading)
    }

    /// `<ZUUID>/L0/001` is a PhotoKit identifier (spike 5, question 3).
    static func uuid(of id: PhotoID) -> String {
        String(id.rawValue.prefix { $0 != "/" })
    }

    private static func double(_ statement: OpaquePointer?, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_double(statement, column)
        return value.isFinite ? value : nil
    }

    private static func columns(of table: String, in db: OpaquePointer?) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "pragma table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    private static func message(_ db: OpaquePointer?) -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "out of memory"
    }
}

/// Where the system library is. Its name cannot be guessed: it is localised
/// when the library is made (`Foto Library` on one Mac, `Photos Library` on
/// another), and an old library may sit beside it (spike 5, question 2).
public enum PhotosLibraryLocator {
    /// The libraries to try, most trusted first: PhotoKit's own answer, a
    /// private property read only if it is there; iCloud Photos' engine,
    /// whose preferences are a plain file; then every library in Pictures.
    /// None is trusted until its identifiers match (`PhotosDatabase.read`).
    /// Other apps' containers are left alone: reading one asks the user.
    public static func candidates() -> [URL] {
        var found: [URL] = []
        let library = PHPhotoLibrary.shared()
        if library.responds(to: NSSelectorFromString("photoLibraryURL")),
           let url = library.value(forKey: "photoLibraryURL") as? URL {
            found.append(url)
        }
        if let parameters = CFPreferencesCopyAppValue(
            "CPLEngineParameters-SystemLibrary" as CFString, "com.apple.cloudphotod" as CFString
        ) as? [String: Any], let base = parameters["clientLibraryBasePath"] as? String,
           let range = base.range(of: ".photoslibrary") {
            found.append(URL(fileURLWithPath: String(base[..<range.upperBound])))
        }
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        let bundles = (try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? []
        found += bundles.filter { $0.pathExtension == "photoslibrary" }.sorted { $0.path < $1.path }

        var seen: Set<String> = []
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func database(in library: URL) -> URL {
        library.appendingPathComponent("database/Photos.sqlite")
    }
}

/// `PhotoQuality` from the database of the library PhotoKit reads.
///
/// Only with full access: before the user has answered, touching the
/// library's files brings up the Photos prompt and blocks until it is
/// answered; with limited access PhotoKit sees only the photographs picked,
/// and whether the files stay readable is not known (spike 5).
public struct PhotosDatabaseQualitySource: PhotoQualitySource {
    private let candidates: @Sendable () -> [URL]
    private let isAuthorized: @Sendable () -> Bool

    public init(
        candidates: @escaping @Sendable () -> [URL] = PhotosLibraryLocator.candidates,
        isAuthorized: @escaping @Sendable () -> Bool = { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }
    ) {
        self.candidates = candidates
        self.isAuthorized = isAuthorized
    }

    public func qualities(of photos: [PhotoDescriptor]) -> [PhotoID: PhotoQuality] {
        guard isAuthorized() else {
            Self.log.notice("no scores: Photos access is not full, the database is not read")
            return [:]
        }
        let started = Date()
        let ids = photos.map(\.id)
        for library in candidates() {
            let database = PhotosLibraryLocator.database(in: library)
            switch PhotosDatabase.read(at: database, ids: ids) {
            case .read(let reading):
                let missing = reading.missing.isEmpty ? "" : ", without \(reading.missing.joined(separator: " and "))"
                Self.log.notice("""
                    scores from \(database.path, privacy: .public): \(reading.matched, privacy: .public) of \
                    \(ids.count, privacy: .public) photographs, \(reading.scored, privacy: .public) scored, \
                    \(reading.placeholders, privacy: .public) not analysed, \(reading.screenshots, privacy: .public) \
                    screenshots, \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms\(missing, privacy: .public)
                    """)
                return reading.qualities
            case .refused(let reason):
                Self.log.notice("no scores from \(library.path, privacy: .public): \(reason, privacy: .public)")
            }
        }
        Self.log.notice("no scores: no library of this Mac has these photographs")
        return [:]
    }

    private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "quality")
}
