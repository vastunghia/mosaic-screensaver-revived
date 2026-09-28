import Foundation
import MosaicPhotos

/// The app's preferences, in its own `UserDefaults`.
///
/// Only the app reads them for now: how the saver gets at them is decided with
/// the saver, at milestone 5 (PLAN.md, milestone 4). They turn into `Options`,
/// so the app runs the effect through exactly the code the harness does.
struct AppPreferences {
    enum Source: String, CaseIterable, Identifiable {
        case photos, folder
        var id: String { rawValue }
    }

    var source: Source = .photos
    var folder: URL?
    /// Empty is the whole library (SPEC § 5).
    var albumIdentifiers: [String] = []
    var allowsDownloads = false
    var subsetRule = SubsetRule.random
    var subsetSize = 2048
    /// Fixed once, at the first launch, and kept: the indexed subset has to
    /// stay the same from one session to the next.
    var subsetSeed: UInt64 = 0
    var rows = 90
    var cycleDuration: Double = 25

    static let rowRange = 60...120
    static let durationRange: ClosedRange<Double> = 10...60

    private enum Key {
        static let source = "source"
        static let folder = "folder"
        static let albums = "albums"
        static let downloads = "allowsDownloads"
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
        preferences.albumIdentifiers = defaults.stringArray(forKey: Key.albums) ?? []
        preferences.allowsDownloads = defaults.bool(forKey: Key.downloads)
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
        defaults.set(albumIdentifiers, forKey: Key.albums)
        defaults.set(allowsDownloads, forKey: Key.downloads)
        defaults.set(subsetRule.rawValue, forKey: Key.rule)
        defaults.set(subsetSize, forKey: Key.size)
        defaults.set(String(subsetSeed), forKey: Key.seed)
        defaults.set(rows, forKey: Key.rows)
        defaults.set(cycleDuration, forKey: Key.duration)
    }

    /// Whether there is anything to index at all.
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
            options.albumIdentifiers = albumIdentifiers
            options.allowsDownloads = allowsDownloads
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
