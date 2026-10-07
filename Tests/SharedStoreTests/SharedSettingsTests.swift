import Foundation
import Testing
@testable import SharedStore

/// The app writes the settings and the .saver reads them: a file either side
/// misreads silently runs the effect with the wrong `R` or `T`.
@Suite("Shared settings")
struct SharedSettingsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("what the app writes is what the saver reads")
    func roundTrip() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = SharedSettings(rows: 72, cycleDuration: 40)
        try settings.write(to: url)
        #expect(SharedSettings.read(from: url) == settings)
    }

    @Test("no file, or one that cannot be read, is nil")
    func unreadable() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(SharedSettings.read(from: url) == nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"rows\": \"many\"}".utf8).write(to: url)
        #expect(SharedSettings.read(from: url) == nil)
    }

    @Test("values outside the app's ranges are clamped, also when read")
    func clamped() throws {
        #expect(SharedSettings(rows: 4, cycleDuration: 1000) == SharedSettings(rows: 60, cycleDuration: 60))
        let decoded = try JSONDecoder().decode(
            SharedSettings.self, from: Data("{\"rows\": 500, \"cycleDuration\": 2}".utf8)
        )
        #expect(decoded == SharedSettings(rows: 120, cycleDuration: 10))
    }
}
