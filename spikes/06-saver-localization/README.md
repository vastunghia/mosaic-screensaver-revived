# Spike 6 — Localization of a .saver inside legacyScreenSaver

## The question

The screen saver's strings will live in a String Catalog compiled into
`Mosaic.saver/Contents/Resources/<lang>.lproj`. Inside `legacyScreenSaver`, `Bundle.main`
is the host, not the saver. Does the saver's own bundle get the user's language there, or
does it follow the host, which ships only `en.lproj` (plus a `Localizable.loctable`)? And if
it does not, what is the fallback?

## The setup

- `LocaleProbe.saver`: a catalog with three keys (a plain string, a plural, a key with no
  Italian translation), compiled by `xcrun xcstringstool compile`, no Xcode project.
  At `init` the view runs `Probe.run(bundle:)` and writes one line per fact to the unified
  log (`subsystem == "dev.mosaic.spike" AND category == "locale"`) and on screen.
- Controls, outside any sandbox, on the same bundle loaded with `Bundle(path:)`:
  - `locale-control`: a command-line tool, so no main bundle;
  - `LocaleHost.app`: an app with only `en.lproj`, like the host;
  - `LocaleHostMixed.app`: the same app with `CFBundleAllowMixedLocalizations`.
- `./build.sh` builds and installs all of it (`NO_LOCALIZATIONS_KEY=1` leaves
  `CFBundleLocalizations` out of the saver's `Info.plist`). The saver is selected by hand in
  System Settings (preview), then run full screen with `open -a ScreenSaverEngine`.

Intel iMac, macOS 15.7.9, Swift 6.2.4, system language `it-IT`, region Italy.

## The result

| | `legacyScreenSaver` | CLI | app, `en` only | app, mixed |
|---|---|---|---|---|
| `Locale.preferredLanguages` | `it`, `it-IT` | `it-IT` | `it-IT` | `it-IT` |
| `Locale.current` | **`en_IT`** | `it_IT` | `en_IT` | `it_IT` |
| `Bundle(for:)` / `Bundle(path:)` `.preferredLocalizations` | **`it`** | `en` | `en` | `it` |
| `String(localized:bundle:)`, `NSLocalizedString` | **Opzioni…** | Options… | Options… | Opzioni… |
| plural, 1 and 2048 | **1 fotografia, 2.048 fotografie** | 1 photograph, 2048 photographs | 1 photograph, 2.048 photographs | 1 fotografia, 2048 fotografie |
| `LocalizedStringResource(bundle: .atURL)` | **Options…** | Opzioni… | Options… | Opzioni… |
| manual resolution (below) | Opzioni…, 2048 fotografie | same | same | same |

Preview and full screen give the same lines.

1. **Inside `legacyScreenSaver` the saver gets its own Italian.** `String(localized:bundle:)`
   with `Bundle(for: View.self)`, `NSLocalizedString` and the plural variations that
   `xcstringstool` writes to a `.stringsdict` all return Italian.
2. **This comes from the host, and nothing guarantees it.** An ordinary app with only
   `en.lproj` makes every bundle it loads follow its own language: `LocaleHost` returns
   English, like the CLI. With `CFBundleAllowMixedLocalizations` the bundle chooses for
   itself. For the saver's own strings `legacyScreenSaver` behaves like the mixed app,
   although its `Info.plist` does not declare the key. For `Locale.current` it behaves like
   the app with only English (next point).
3. **`Locale.current` in the host is `en_IT`**: the host's only language with the user's
   region. Two consequences:
   - `LocalizedStringResource` resolves against `Locale.current` and stays in English;
   - numbers interpolated into a string are formatted for `en_IT`: «2.048 fotografie»,
     where Italian writes «2048 fotografie». CLDR does not group four-digit numbers in
     Italian.
4. **Resolving the language by hand works in every host**:
   - the language is `Bundle.preferredLocalizations(from: bundle.localizations,
     forPreferences: Locale.preferredLanguages).first`;
   - the key is looked up in that language's `.lproj` as a `Bundle`;
   - the text is formatted with a `Locale` made of that language and
     `Locale.current.region`, passed as `locale:`.

   That gives Opzioni…, 1 fotografia and 2048 fotografie in all four hosts. With
   `-AppleLanguages (de-DE)` the controls fall back to English, with German digit grouping.
5. **Language preferences for one app do not reach the host.** The host's language list
   stayed `it`, `it-IT` with `AppleLanguages` set to `de-DE`:
   - in the `legacyScreenSaver` container's preferences;
   - in `com.apple.ScreenSaver.Engine`'s preferences.

   Both were removed afterwards. The saver follows the system language. A system language
   other than Italian was not tried, because that means changing the account's language.
6. **`CFBundleLocalizations` is not needed in the saver.** Without the key the result is
   the same. With it, `Bundle.localizations` lists every language twice.
7. **`xcstringstool compile` writes only languages that have values.** With the keys
   in English, `en.lproj` gets only the `.stringsdict` (the plurals), and no `.strings` at
   all if there are no plurals. `Bundle.localizations` still lists `en`, because it is the
   development region, and English users still get the keys. Nothing to add.

## What changes in the plan

- **Every string in the saver goes through one small helper.** The helper resolves the
  language by hand, once (point 4). It does not rely on the host's behaviour in point 2,
  which is undocumented and has not been checked on macOS 26.
- **No `LocalizedStringResource` or `Locale.current` in the saver.** Numbers are
  formatted with the helper's locale.
- **No `CFBundleLocalizations` in the saver's `Info.plist`.** For the app it is decided in A1.
- On macOS 26 (an Apple Silicon laptop), the saver's language is still to be checked once.
- To try the saver in English, the system language has to change. A per-app language
  for the host does nothing.
