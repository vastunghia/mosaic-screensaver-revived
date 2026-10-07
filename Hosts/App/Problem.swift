/// What went wrong last, and where it belongs: the window shows it in that
/// step, next to what it is about, not in a corner of the window.
struct Problem: Equatable {
    enum Place {
        case location, photographs, preparing, screenSaver, settings
    }

    let place: Place
    let message: String
}
