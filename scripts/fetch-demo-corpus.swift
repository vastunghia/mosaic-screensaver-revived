// Downloads the photographs the README's video is made from: landscape
// photographs from the WordPress Photo Directory, which publishes everything
// under CC0 (https://wordpress.org/photos/license/).
//
//     swift scripts/fetch-demo-corpus.swift <directory> [count]
//
// The same photographs every time: ascending identifiers, fixed pages spread
// over the whole directory, so photographs added later fall outside them.
// Interrupted, it picks up where it stopped. credits.csv, next to the
// photographs, says where each one comes from.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: fetch-demo-corpus.swift <directory> [count]\n".data(using: .utf8)!)
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let wanted = arguments.count >= 3 ? Int(arguments[2]) ?? 2048 : 2048

/// The directory's taxonomy term for landscape photographs.
let landscape = 23
let perPage = 100
/// Every tenth page: 2,100 photographs out of the first 21,000 landscape ones.
let pages = (0..<21).map { 1 + $0 * 10 }

struct Photo: Sendable {
    let id: Int
    let page: String
    let image: URL
}

func fetchPage(_ page: Int) async throws -> [Photo] {
    var components = URLComponents(string: "https://wordpress.org/photos/wp-json/wp/v2/photos")!
    components.queryItems = [
        URLQueryItem(name: "per_page", value: "\(perPage)"),
        URLQueryItem(name: "page", value: "\(page)"),
        URLQueryItem(name: "photo-orientations", value: "\(landscape)"),
        URLQueryItem(name: "orderby", value: "id"),
        URLQueryItem(name: "order", value: "asc"),
        URLQueryItem(name: "_embed", value: "wp:featuredmedia"),
    ]
    let (data, _) = try await URLSession.shared.data(from: components.url!)
    guard let photos = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return photos.compactMap { photo in
        guard let id = photo["id"] as? Int, let link = photo["link"] as? String,
              let embedded = photo["_embedded"] as? [String: Any],
              let media = (embedded["wp:featuredmedia"] as? [[String: Any]])?.first,
              let details = media["media_details"] as? [String: Any],
              let sizes = details["sizes"] as? [String: Any]
        else { return nil }
        // 2048 wide is past what the effect needs (close-ups anchor at 1920);
        // the original, often 5000 wide or more, only costs.
        let size = (sizes["2048x2048"] ?? sizes["full"]) as? [String: Any]
        guard let source = size?["source_url"] as? String, let url = URL(string: source) else { return nil }
        return Photo(id: id, page: link, image: url)
    }
}

func download(_ photo: Photo) async -> Bool {
    let file = directory.appendingPathComponent("\(photo.id).jpg")
    if FileManager.default.fileExists(atPath: file.path) { return true }
    do {
        let (temporary, response) = try await URLSession.shared.download(from: photo.image)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        try FileManager.default.moveItem(at: temporary, to: file)
        return true
    } catch {
        return false
    }
}

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var photos: [Photo] = []
for page in pages {
    let found = try await fetchPage(page)
    print("page \(page): \(found.count) photographs")
    photos += found
}
photos = Array(photos.prefix(wanted))

var fetched: [Photo] = []
for batch in stride(from: 0, to: photos.count, by: 8).map({ Array(photos[$0..<min($0 + 8, photos.count)]) }) {
    let results = await withTaskGroup(of: (Photo, Bool).self) { group in
        for photo in batch { group.addTask { (photo, await download(photo)) } }
        return await group.reduce(into: [(Photo, Bool)]()) { $0.append($1) }
    }
    fetched += results.filter(\.1).map(\.0)
    if fetched.count % 200 < 8 { print("\(fetched.count) of \(photos.count)") }
}

var credits = "file,photograph,image\n"
for photo in fetched.sorted(by: { $0.id < $1.id }) {
    credits += "\(photo.id).jpg,\(photo.page),\(photo.image.absoluteString)\n"
}
try credits.write(to: directory.appendingPathComponent("credits.csv"), atomically: true, encoding: .utf8)
print("\(fetched.count) photographs in \(directory.path), CC0, from the WordPress Photo Directory")
if fetched.count < photos.count { print("\(photos.count - fetched.count) could not be downloaded; run again to retry") }
