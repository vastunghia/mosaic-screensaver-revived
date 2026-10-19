// Spike 6 — which localization does a .saver get inside legacyScreenSaver?
//
// The same probe runs in two places: inside the screen saver (LocaleProbeView) and in a
// command-line control outside any sandbox (control.swift), so that a difference between
// the two is the host's doing and not the code's.

import Foundation

enum Probe {

    /// One line per fact, "name = value", so that the two runs can be diffed.
    static func run(bundle b: Bundle) -> [String] {
        var lines: [String] = []
        func put(_ name: String, _ value: Any?) {
            lines.append("\(name) = \(value.map { "\($0)" } ?? "nil")")
        }

        put("process", ProcessInfo.processInfo.processName)
        put("sandbox", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "(none)")
        put("Locale.preferredLanguages", Locale.preferredLanguages)
        put("AppleLanguages default", UserDefaults.standard.array(forKey: "AppleLanguages"))
        put("Locale.current", Locale.current.identifier)
        put("2048.formatted()", 2048.formatted())

        put("main.bundleIdentifier", Bundle.main.bundleIdentifier)
        put("main.localizations", Bundle.main.localizations)
        put("main.preferredLocalizations", Bundle.main.preferredLocalizations)

        put("bundle.bundleIdentifier", b.bundleIdentifier)
        put("bundle.developmentLocalization", b.developmentLocalization)
        put("bundle.localizations", b.localizations)
        put("bundle.preferredLocalizations", b.preferredLocalizations)
        put("preferredLocalizations(from:)", Bundle.preferredLocalizations(from: b.localizations))
        put("preferredLocalizations(from:forPreferences: Locale.preferredLanguages)",
            Bundle.preferredLocalizations(from: b.localizations,
                                          forPreferences: Locale.preferredLanguages))

        // The three spellings the real saver could use.
        put("String(localized:bundle:)", String(localized: "Options…", bundle: b,
                                                 comment: "Button that opens the options sheet"))
        put("NSLocalizedString", NSLocalizedString("Options…", bundle: b,
                                                   comment: "Button that opens the options sheet"))
        put("LocalizedStringResource(.atURL)",
            String(localized: LocalizedStringResource("Options…", bundle: .atURL(b.bundleURL))))

        // Plurals come from the .stringsdict that xcstringstool writes beside the .strings.
        for n in [1, 2048] {
            put("plural \(n)", String(localized: "\(n) photographs", bundle: b,
                                      comment: "How many photographs the subset holds"))
        }

        // A key with no Italian translation: should fall back to the English value.
        put("untranslated", String(localized: "Only in English", bundle: b,
                                   comment: "A key left untranslated on purpose"))

        // The fallback, independent of the host: choose the language ourselves, look the
        // key up in that .lproj, and format with a locale made of that language and the
        // user's region.
        let language = Bundle.preferredLocalizations(from: b.localizations,
                                                     forPreferences: Locale.preferredLanguages)
            .first ?? b.developmentLocalization ?? "en"
        let lproj = b.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? b
        var components = Locale.Components(identifier: language)
        components.region = Locale.current.region
        let locale = Locale(components: components)
        put("manual language", language)
        put("manual locale", locale.identifier)
        put("manual Options…", String(localized: "Options…", bundle: lproj, locale: locale,
                                       comment: "Button that opens the options sheet"))
        for n in [1, 2048] {
            put("manual plural \(n)", String(localized: "\(n) photographs", bundle: lproj, locale: locale,
                                             comment: "How many photographs the subset holds"))
        }
        put("manual 2048.formatted()", 2048.formatted(.number.locale(locale)))
        put("manual untranslated", String(localized: "Only in English", bundle: lproj, locale: locale,
                                          comment: "A key left untranslated on purpose"))

        return lines
    }
}
