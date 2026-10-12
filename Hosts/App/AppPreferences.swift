import Foundation
import MosaicPhotos
import SharedStore

/// The app's preferences, in its own `UserDefaults`.
///
/// They turn into `Options`, so the app runs the effect through exactly the
/// code the harness does. The .saver has no preferences of its own: what it
/// needs, `R` and `T`, the app hands it as `SharedSettings` (milestone 5).
struct AppPreferences: Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case photos, folder
        var id: String { rawValue }
    }

    var source: Source = .photos
    var folder: URL?
    /// Albums and folders. Empty is the whole library (SPEC § 5).
    var collectionIdentifiers: [String] = []
    /// What may be fetched from iCloud (SPEC § 5). Nil until the user has
    /// answered, which fetches nothing: the question comes as a sheet, and
    /// only to a library that needs it (`AppModel.asksAboutDownloads`).
    var downloads: Downloads?
    var subsetRule = SubsetRule.uniformInTime
    var subsetSize = 2048
    /// Fixed once, at the first launch, and kept: the indexed subset has to
    /// stay the same from one session to the next.
    var subsetSeed: UInt64 = 0
    var rows = 90
    var cycleDuration: Double = 25

    /// From nothing to anything the index needs: never a surprise on the
    /// user's disk or bill (Sergio, 2026-10-12).
    enum Downloads: String, CaseIterable, Identifiable {
        /// What this Mac has; close-ups of the rest come from thumbnails.
        case nothing
        /// A 1920 px copy of each photograph that fills the screen and has
        /// none here, within `DownloadLedger`'s caps; never an original.
        case closeUps
        /// Whatever indexing needs, originals included: the last resort.
        case everything

        var id: String { rawValue }
    }

    static let rowRange = SharedSettings.rowRange
    static let durationRange = SharedSettings.durationRange

    private enum Key {
        static let source = "source"
        static let folder = "folder"
        static let albums = "albums"
        /// The switch the three choices replaced: on was `everything`.
        static let allowsDownloads = "allowsDownloads"
        static let downloads = "iCloudDownloads"
        static let rule = "subsetRule"
        static let size = "subsetSize"
        static let seed = "subsetSeed"
        static let rows = "rows"
        static let duration = "cycleDuration"
    }

    static func load(from defaults: UserDefaults = .standard) -> AppPreferences {
        var preferences = AppPreferences()
        if let raw = defaults.string(forKey: Key.source), let source = Source(rawValue: raw) {
            preferences.source = source
        }
        preferences.folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0) }
        preferences.collectionIdentifiers = defaults.stringArray(forKey: Key.albums) ?? []
        if let raw = defaults.string(forKey: Key.downloads) {
            preferences.downloads = Downloads(rawValue: raw)
        } else if defaults.bool(forKey: Key.allowsDownloads) {
            preferences.downloads = .everything
        }
        if let raw = defaults.string(forKey: Key.rule), let rule = SubsetRule(rawValue: raw) {
            preferences.subsetRule = rule
        }
        if defaults.object(forKey: Key.size) != nil {
            preferences.subsetSize = max(100, defaults.integer(forKey: Key.size))
        }
        if defaults.object(forKey: Key.rows) != nil {
            preferences.rows = min(max(defaults.integer(forKey: Key.rows), rowRange.lowerBound), rowRange.upperBound)
        }
        if defaults.object(forKey: Key.duration) != nil {
            preferences.cycleDuration = min(max(defaults.double(forKey: Key.duration), durationRange.lowerBound),
                                            durationRange.upperBound)
        }

        // A UInt64 does not fit a property list number, so it is kept as text.
        if let text = defaults.string(forKey: Key.seed), let seed = UInt64(text) {
            preferences.subsetSeed = seed
        } else {
            preferences.subsetSeed = UInt64.random(in: .min ... .max)
            defaults.set(String(preferences.subsetSeed), forKey: Key.seed)
        }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: Key.source)
        defaults.set(folder?.path, forKey: Key.folder)
        defaults.set(collectionIdentifiers, forKey: Key.albums)
        defaults.set(downloads?.rawValue, forKey: Key.downloads)
        defaults.removeObject(forKey: Key.allowsDownloads)
        defaults.set(subsetRule.rawValue, forKey: Key.rule)
        defaults.set(subsetSize, forKey: Key.size)
        defaults.set(String(subsetSeed), forKey: Key.seed)
        defaults.set(rows, forKey: Key.rows)
        defaults.set(cycleDuration, forKey: Key.duration)
    }

    /// What the .saver needs of them.
    var shared: SharedSettings {
        SharedSettings(rows: rows, cycleDuration: cycleDuration)
    }

    /// Whether there is anything to index at all.
    /// `rows` for a slider, which moves in doubles.
    var rowsForSlider: Double {
        get { Double(rows) }
        set { rows = Int(newValue.rounded()) }
    }

    var hasSource: Bool {
        source == .photos || folder != nil
    }

    /// The harness's options for these preferences, with a new seed for the
    /// session: no two sessions show the same sequence (SPEC § 5).
    func options() -> Options {
        var options = Options()
        switch source {
        case .photos:
            options.photosLibrary = true
            options.collectionIdentifiers = collectionIdentifiers
            options.allowsDownloads = downloads == .everything
            options.fetchesCloseUps = downloads == .closeUps
            options.subsetRule = subsetRule
            options.subsetSize = subsetSize
            options.subsetSeed = subsetSeed
        case .folder:
            options.folder = folder
        }
        options.rows = rows
        options.cycleDuration = cycleDuration
        options.seed = UInt64.random(in: .min ... .max)
        options.seedIsPerLaunch = true
        return options
    }
}
