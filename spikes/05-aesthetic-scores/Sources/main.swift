// Spike 5. Question 1: can an app with only the Photos permission read the
// Photos library's own databases (Photos.sqlite, search/psi.sqlite)?
// Questions 2 and 3 (`--match`): where the system library is, and whether
// PhotoKit's identifiers are the database's.
//
//   Spike5Probe [--request] [--library <path.photoslibrary>]
//   Spike5Probe --match
//   Spike5Probe --previews <out dir> --ids <file of UUIDs> [--side 640]
//   Spike5Probe --vision <out dir> [--manifest <manifest.json> | --sample N] [--sizes 854,427]
//               [--limit N] [--no-previews]
//
// Prints one line per check. Run it through `open -W --stdout` so TCC sees the
// probe's own identity; run the binary directly from Terminal for the control.
import Foundation
import Photos
import SQLite3

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func describe(_ s: PHAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .authorized: "authorized"
    case .limited: "limited"
    @unknown default: "unknown(\(s.rawValue))"
    }
}

print("process: \(ProcessInfo.processInfo.processName) pid \(getpid()) bundle \(Bundle.main.bundleIdentifier ?? "-")")
var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
print("photos.status: \(describe(status))")
if args.contains("--request"), status == .notDetermined {
    let sem = DispatchSemaphore(value: 0)
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status = $0; sem.signal() }
    sem.wait()
    print("photos.status.afterRequest: \(describe(status))")
}

// Where the system library is, without asking PhotoKit (which does not say).
func discover() -> [String: String] {
    var found: [String: String] = [:]
    if let data = CFPreferencesCopyAppValue("IPXDefaultLibraryURLBookmark" as CFString, "com.apple.Photos" as CFString) as? Data {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
            found["photos.bookmark"] = url.path
        } else {
            found["photos.bookmark"] = "<unresolvable, \(data.count) bytes>"
        }
    } else {
        found["photos.bookmark"] = "<absent>"
    }
    if let keys = CFPreferencesCopyKeyList("com.apple.photolibraryd" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
        var paths = Set<String>()
        for key in keys {
            if let list = CFPreferencesCopyAppValue(key as CFString, "com.apple.photolibraryd" as CFString) as? [String] {
                paths.formUnion(list.filter { $0.hasSuffix(".photoslibrary") })
            }
        }
        found["photolibraryd.paths"] = paths.isEmpty ? "<none>" : paths.sorted().joined(separator: " | ")
    } else {
        found["photolibraryd.paths"] = "<no keys>"
    }
    return found
}
for (key, path) in discover().sorted(by: { $0.key < $1.key }) { print("discover.\(key): \(path)") }

if let out = value("--previews"), let ids = value("--ids") {
    runPreviews(out: out, ids: ids, side: value("--side").flatMap(Int.init) ?? 640)
    exit(0)
}
if let out = value("--vision") {
    let manifest = value("--manifest")
        ?? NSString(string: "~/Library/Application Support/Mosaic/index/manifest.json").expandingTildeInPath
    let sizes = (value("--sizes") ?? "854").split(separator: ",").compactMap { Int($0) }
    let limit = value("--limit").flatMap(Int.init) ?? .max
    guard #available(macOS 15.0, *) else {
        print("vision: skipped, CalculateImageAestheticsScoresRequest needs macOS 15")
        exit(0)
    }
    let sample = value("--sample").flatMap(Int.init)
    let done = DispatchSemaphore(value: 0)
    Task {
        await runVision(out: out, manifest: manifest, sample: sample, sizes: sizes, limit: limit,
                        previews: !args.contains("--no-previews"))
        done.signal()
    }
    done.wait()
    exit(0)
}
if args.contains("--match") {
    runMatch()
    exit(0)
}

let library = value("--library") ?? NSString(string: "~/Pictures/Foto Library.photoslibrary").expandingTildeInPath
print("library: \(library)")

func errnoText() -> String { "errno \(errno) \(String(cString: strerror(errno)))" }

func probeDirectory(_ path: String) {
    do {
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        print("  list \(path): ok, \(names.count) entries")
    } catch {
        print("  list \(path): FAILED \((error as NSError).domain) \((error as NSError).code)")
    }
}

func probeFile(_ path: String, query: String) {
    print("file: \(path.replacingOccurrences(of: library + "/", with: ""))")
    var st = stat()
    print("  stat: " + (stat(path, &st) == 0 ? "ok, \(st.st_size) bytes" : "FAILED \(errnoText())"))
    let fd = open(path, O_RDONLY)
    if fd >= 0 {
        var header = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &header, 16)
        print("  open+read: " + (n == 16 ? "ok, \(String(decoding: header.prefix(15), as: UTF8.self))" : "read FAILED \(errnoText())"))
        close(fd)
    } else {
        print("  open: FAILED \(errnoText())")
    }
    for mode in ["mode=ro&immutable=1", "mode=ro"] {
        var db: OpaquePointer?
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?" + mode
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK else {
            print("  sqlite \(mode): open FAILED rc \(rc) \(String(cString: sqlite3_errmsg(db)))")
            continue
        }
        var stmt: OpaquePointer?
        let start = Date()
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            let cols = (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)) }
            print("  sqlite \(mode): ok, \(cols.joined(separator: " / ")) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } else {
            print("  sqlite \(mode): query FAILED \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
    }
}

// Positive control: places Full Disk Access guards. If these list, the probe is
// not under TCC and the checks below prove nothing.
for guarded in ["~/Library/Mail", "~/Library/Safari", "~/Library/Application Support/com.apple.TCC"] {
    probeDirectory(NSString(string: guarded).expandingTildeInPath)
}
probeDirectory(library)
probeDirectory(library + "/database")
probeFile(library + "/database/Photos.sqlite",
          query: "select count(*), sum(ZOVERALLAESTHETICSCORE > 0) from ZASSET where ZTRASHEDSTATE = 0 and ZKIND = 0")
probeFile(library + "/database/search/psi.sqlite",
          query: "select count(*) from ga join groups g on g.rowid = ga.groupid where g.category = 2800")

// The control for the file checks: PhotoKit itself, under the same identity.
if status == .authorized || status == .limited {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: options)
    print("photokit: \(assets.count) images, first \(assets.firstObject?.localIdentifier ?? "-")")
}
print("done")
