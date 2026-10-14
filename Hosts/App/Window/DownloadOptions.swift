import PhotoIndex
import SwiftUI

/// What Mosaic may fetch from iCloud, said with what it costs: the user's
/// disk and possibly their bill, so nothing happens they have not chosen
/// (SPEC § 5). Unanswered, it shows as None, which is what it does.
struct DownloadOptions: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Picker("Download from iCloud", selection: Binding(
                get: { model.preferences.downloads ?? .nothing },
                set: { model.preferences.downloads = $0 }
            )) {
                Text("Nothing").tag(AppPreferences.Downloads.nothing)
                Text("Sharp close-ups only").tag(AppPreferences.Downloads.closeUps)
                Text("Everything needed").tag(AppPreferences.Downloads.everything)
            }
            if model.preferences.downloads == .closeUps, model.closeUpsWaiting?.reason == .limits {
                LabeledContent("Daily or weekly limit reached") {
                    DownloadLimitsReset(model: model)
                }
            }
        } footer: {
            Footnote(footnote)
        }
    }

    private var footnote: String {
        switch model.preferences.downloads ?? .nothing {
        case .nothing:
            return "Mosaic uses only what Photos keeps on this Mac. If your library keeps originals in iCloud, only the photographs this Mac keeps large are shown full screen, often from a few years only, and some close-ups are blurry."
        case .closeUps:
            let recent = model.closeUpsFetchedThisWeek
            let ring = model.ringCopiesAtMost
            let around = ring > 0 ? ", and of up to \(ring.formatted()) of the photographs shown large around them" : ""
            return "The photographs shown full screen, one in sixteen, are chosen from your whole library, and Mosaic downloads a sharp copy of each that this Mac lacks\(around), about 1.3 MB each, never the original: at most \(DownloadLedger.standardDailyLimit) a day and \(DownloadLedger.standardWeeklyLimit) a week, and none on a hotspot or in Low Data Mode. Photos keeps them in your library until it needs the space. "
                + (recent == 1 ? "1 downloaded in the last 7 days." : "\(recent) downloaded in the last 7 days.")
        case .everything:
            return "Mosaic downloads whatever it needs to prepare your photographs, originals included. It can take a long time and a lot of space on disk: choose it only if too few photographs are ready otherwise."
        }
    }
}
