import Foundation

/// The language the screen saver speaks, and the locale it formats in.
///
/// Inside `legacyScreenSaver`, `Bundle.main` is the host, which has only
/// English. On macOS 15 the host lets this bundle pick its own `.lproj`, but
/// nothing documents it, and `Locale.current` there is English with the user's
/// region (spike 6). So the language is resolved here, once, from the user's
/// preferences and the languages this bundle has, and every string names both:
///
///     String(localized: "Done", bundle: SaverLanguage.bundle,
///            locale: SaverLanguage.locale, comment: "…")
///
/// Spelled out at each call rather than wrapped: the compiler extracts a key
/// and its comment for the String Catalog only from `String(localized:)`.
enum SaverLanguage {
    private static let saver = Bundle(for: MosaicSaverView.self)

    /// One of the bundle's languages, English when none of the user's is there.
    static let language = Bundle.preferredLocalizations(
        from: saver.localizations, forPreferences: Locale.preferredLanguages
    ).first ?? saver.developmentLocalization ?? "en"

    /// That language's `.lproj`, where its strings are looked up.
    static let bundle = saver.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? saver

    /// The language with the user's region, for numbers and dates: 2048 in
    /// Italian, where the host's `en_IT` writes 2.048.
    static let locale: Locale = {
        var components = Locale.Components(identifier: language)
        components.region = Locale.current.region
        return Locale(components: components)
    }()
}
