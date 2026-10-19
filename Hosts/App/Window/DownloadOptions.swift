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
            return String(localized: "Mosaic Companion uses only what Photos keeps on this Mac. If your library keeps originals in iCloud, only the photographs this Mac keeps large are shown full screen, often from a few years only, and some close-ups are blurry.",
                          comment: "Settings, Download from iCloud: what Nothing means")
        case .closeUps:
            let daily = DownloadLedger.standardDailyLimit
            let weekly = DownloadLedger.standardWeeklyLimit
            let ring = model.ringCopiesAtMost
            let what = ring > 0
                ? String(localized: "The photographs shown full screen, one in sixteen, are chosen from your whole library, and Mosaic Companion downloads a sharp copy of each that this Mac lacks, and of up to \(ring) of the photographs shown large around them, about 1.3 MB each, never the original: at most \(daily) a day and \(weekly) a week, and none on a hotspot or in Low Data Mode. Photos keeps them in your library until it needs the space.",
                         comment: "Settings, Download from iCloud: what Sharp close-ups only means, when tiles around them are downloaded too")
                : String(localized: "The photographs shown full screen, one in sixteen, are chosen from your whole library, and Mosaic Companion downloads a sharp copy of each that this Mac lacks, about 1.3 MB each, never the original: at most \(daily) a day and \(weekly) a week, and none on a hotspot or in Low Data Mode. Photos keeps them in your library until it needs the space.",
                         comment: "Settings, Download from iCloud: what Sharp close-ups only means")
            let recent = String(localized: "\(model.closeUpsFetchedThisWeek) downloaded in the last 7 days.",
                                comment: "Settings, Download from iCloud: sharp copies downloaded this week")
            return what + " " + recent
        case .everything:
            return String(localized: "Mosaic Companion downloads whatever it needs to prepare your photographs, originals included. It can take a long time and a lot of space on disk: choose it only if too few photographs are ready otherwise.",
                          comment: "Settings, Download from iCloud: what Everything needed means")
        }
    }
}
