import Foundation

/// M11: how the .saver calls the app.
///
/// Spike 4: inside `legacyScreenSaver` the saver can launch the app, but the
/// arguments it passes are dropped on the way; a URL arrives whole, as a `GURL`
/// Apple event, and the app is launched by LaunchServices with its own Photos
/// grant. So what the saver has to say travels in the URL, and this is the one
/// place both sides spell it.
public enum MosaicURL: Equatable, Sendable {
    /// Show the app's window: someone is there to use it.
    case open
    /// Bring the index up to date in the background, without a window.
    /// `reason` is only reported, never acted on.
    case update(reason: String)

    public static let scheme = "mosaic"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .open:
            components.host = "open"
        case .update(let reason):
            components.host = "update"
            components.queryItems = [URLQueryItem(name: "reason", value: reason)]
        }
        // Only a scheme, a host and a query: always a valid URL.
        return components.url!
    }

    /// Nil for anything that is not one of ours: anyone can open a `mosaic:`
    /// URL, so an unknown one is ignored, not guessed at.
    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme
        else { return nil }
        switch components.host?.lowercased() {
        case "open":
            self = .open
        case "update":
            let reason = components.queryItems?.first { $0.name == "reason" }?.value
            self = .update(reason: reason ?? "unspecified")
        default:
            return nil
        }
    }
}
