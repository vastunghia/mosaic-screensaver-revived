import Foundation
import Photos
import SQLite3

/// Candidate locations of the system library, each with how it was found.
func candidateLibraries() -> [(source: String, path: String)] {
    var found: [(String, String)] = []
    // PhotoKit's own answer, through a private property.
    let library = PHPhotoLibrary.shared()
    if library.responds(to: NSSelectorFromString("photoLibraryURL")),
       let url = library.value(forKey: "photoLibraryURL") as? URL {
        found.append(("PHPhotoLibrary.photoLibraryURL", url.path))
    } else {
        print("discover.PHPhotoLibrary.photoLibraryURL: <not available>")
    }
    // iCloud Photos' engine, which keeps its paths in a plain preferences file.
    if let parameters = CFPreferencesCopyAppValue("CPLEngineParameters-SystemLibrary" as CFString,
                                                  "com.apple.cloudphotod" as CFString) as? [String: Any],
       let base = parameters["clientLibraryBasePath"] as? String,
       let range = base.range(of: ".photoslibrary") {
        found.append(("cloudphotod.clientLibraryBasePath", String(base[..<range.upperBound])))
    } else {
        print("discover.cloudphotod: <absent>")
    }
    return found
}

func uuids(in database: String, _ sql: String) -> [String: [String]]? {
    var db: OpaquePointer?
    let uri = "file:" + database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        print("  open FAILED \(String(cString: sqlite3_errmsg(db)))")
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("  query FAILED \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [String: [String]] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        let uuid = String(cString: sqlite3_column_text(stmt, 0))
        rows[uuid] = (1..<sqlite3_column_count(stmt)).map {
            sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "null"
        }
    }
    return rows
}

/// Question 4: every asset of the database, with what identifies it across
/// devices, so two profiles on one iCloud library can be compared row by row.
func dump(database: String, visible: Set<String>, to file: String) {
    guard let rows = uuids(in: database, """
        select a.ZUUID, a.ZCLOUDASSETGUID, a.ZKIND, a.ZTRASHEDSTATE, a.ZHIDDEN, a.ZVISIBILITYSTATE,
               a.ZOVERALLAESTHETICSCORE, a.ZCURATIONSCORE, c.ZFAILURESCORE, a.ZISDETECTEDSCREENSHOT,
               m.ZMEDIAANALYSISVERSION, a.ZANALYSISSTATEMODIFICATIONDATE, a.ZDATECREATED
        from ZASSET a
        left join ZCOMPUTEDASSETATTRIBUTES c on c.ZASSET = a.Z_PK
        left join ZMEDIAANALYSISASSETATTRIBUTES m on m.ZASSET = a.Z_PK
        """) else { return }
    var csv = "uuid,cloud_guid,kind,trashed,hidden,visibility,score,curation,failure,screenshot,analysis_version,analysis_date,created,photokit\n"
    for (uuid, r) in rows.sorted(by: { $0.key < $1.key }) {
        csv += ([uuid] + r + [visible.contains(uuid) ? "1" : "0"]).joined(separator: ",") + "\n"
    }
    do {
        try csv.write(toFile: file, atomically: true, encoding: .utf8)
        print("  dump: \(rows.count) rows to \(file)")
    } catch {
        print("  dump FAILED \(error)")
    }
}

func runMatch() {
    // Every image PhotoKit can see, hidden and burst members included, so a
    // difference with the database is a difference of identity, not of filter.
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.includeHiddenAssets = true
    options.includeAllBurstAssets = true
    let start = Date()
    let fetch = PHAsset.fetchAssets(with: options)
    var kit: [String: PHAsset] = [:]
    var shapes: [String: Int] = [:]
    fetch.enumerateObjects { asset, _, _ in
        let id = asset.localIdentifier
        let parts = id.split(separator: "/", maxSplits: 1)
        shapes[parts.count == 2 ? "<uuid>/" + parts[1] : "<other>", default: 0] += 1
        kit[String(parts[0])] = asset
    }
    print("photokit: \(kit.count) images in \(Int(Date().timeIntervalSince(start) * 1000)) ms, identifier shapes \(shapes)")

    var dumped = false
    for (source, path) in candidateLibraries() {
        print("discover.\(source): \(path)")
        let database = path + "/database/Photos.sqlite"
        let start = Date()
        guard let rows = uuids(in: database, """
            select ZUUID, ZTRASHEDSTATE, ZKIND, ZHIDDEN, ZVISIBILITYSTATE, ZAVALANCHEPICKTYPE,
                   ZOVERALLAESTHETICSCORE is not null
            from ZASSET
            """) else { continue }
        print("  database: \(rows.count) assets in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        let both = Set(kit.keys).intersection(rows.keys)
        let kitOnly = Set(kit.keys).subtracting(rows.keys)
        print("  photokit images found in the database: \(both.count) of \(kit.count), missing \(kitOnly.count)")
        for id in kitOnly.sorted().prefix(5) { print("    missing \(id)") }
        if !dumped, let file = CommandLine.arguments.firstIndex(of: "--dump").map({ CommandLine.arguments[$0 + 1] }) {
            dump(database: database, visible: Set(kit.keys), to: file)
            dumped = true
        }
        let matched = both.map { rows[$0]! }
        let notImage = matched.filter { $0[1] != "0" }.count
        let trashed = matched.filter { $0[0] != "0" }.count
        let scored = matched.filter { $0[5] == "1" }.count
        print("  of the matched: kind≠0 \(notImage), trashed \(trashed), scored \(scored)")
        // Database images PhotoKit does not return, grouped by why they might be filtered.
        let dbOnly = rows.filter { kit[$0.key] == nil && $0.value[1] == "0" && $0.value[0] == "0" }
        var why: [String: Int] = [:]
        for (_, r) in dbOnly { why["hidden \(r[2]) visibility \(r[3]) avalanche \(r[4])", default: 0] += 1 }
        print("  database images (kind 0, not trashed) PhotoKit does not return: \(dbOnly.count)")
        for (key, n) in why.sorted(by: { $0.value > $1.value }).prefix(8) { print("    \(n)× \(key)") }
    }
    print("done")
}
