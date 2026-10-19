import Foundation

/// When the setup opens by itself: at the first launch with a window, and
/// again, whole, after an update that adds or changes one of its pages
/// (Sergio, 2026-10-15). Never at login or for `mosaic://update`, when
/// nobody is there to go through it.
enum SetupAssistant {
    /// Bumped by the version that adds a page or changes what one asks.
    static let revision = 1

    /// Whether the setup is due: a revision the user has not finished yet.
    /// Closed halfway, it is put off until the next launch, not skipped.
    static var isDue: Bool {
        UserDefaults.standard.integer(forKey: seenKey) < revision
    }

    /// Done, on the last page.
    static func finish() {
        UserDefaults.standard.set(revision, forKey: seenKey)
    }

    private static let seenKey = "setupRevisionSeen"
}

/// One page of the setup, in the order shown.
enum SetupPage: CaseIterable {
    case welcome, location, photographs, screenSaver, background, downloads, updates, done

    /// The pages this Mac needs now. Recomputed as answers come in: the
    /// downloads page appears once the library may be read.
    @MainActor static func pages(for model: AppModel) -> [SetupPage] {
        allCases.filter { page in
            switch page {
            case .location: model.isTranslocated
            case .downloads: model.preferences.source == .photos && model.access.isGranted
            default: true
            }
        }
    }

    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome to Mosaic", comment: "Setup page title")
        case .location: String(localized: "Applications", comment: "Setup page title: moving the app to the Applications folder")
        case .photographs: String(localized: "Photographs", comment: "Setup page title")
        case .screenSaver: String(localized: "Screen Saver", comment: "Setup page title")
        case .background: String(localized: "In the Background", comment: "Setup page title: opening at login")
        case .downloads: String(localized: "Photos in iCloud", comment: "Setup page title")
        case .updates: String(localized: "Updates", comment: "Setup page title")
        case .done: String(localized: "Mosaic Is Set Up", comment: "Setup page title, last page")
        }
    }

    /// Whether what the page asks for is in place; nil for a page that asks
    /// nothing.
    @MainActor func isDone(_ model: AppModel) -> Bool? {
        switch self {
        case .welcome, .done: return nil
        case .location: return !model.isTranslocated
        case .photographs: return model.hasPhotographs
        case .screenSaver: return model.saver == .installed
        case .background: return model.opensAtLogin
        case .downloads: return model.preferences.downloads != nil
        case .updates: return model.hasAnsweredNotifications
        }
    }
}
