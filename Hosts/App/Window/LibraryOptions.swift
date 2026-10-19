import MosaicPhotoKit
import MosaicPhotos
import SwiftUI

/// Which photographs of the library: albums, how they are picked, how many.
struct LibraryOptions: View {
    @ObservedObject var model: AppModel
    @State private var choosingAlbums = false

    var body: some View {
        Section {
            HStack {
                LabeledContent("Albums") {
                    Text(model.albumSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Button("Choose…", action: chooseAlbums)
                    .disabled(model.albums.isEmpty)
            }
            Picker("Which photographs", selection: $model.preferences.subsetRule) {
                Text("Random").tag(SubsetRule.random)
                Text("Most recent").tag(SubsetRule.recent)
                Text("Spread over time").tag(SubsetRule.uniformInTime)
            }
            Picker("How many", selection: $model.preferences.subsetSize) {
                ForEach(sizes, id: \.self) { size in
                    Text(size.formatted()).tag(size)
                }
            }
        } header: {
            Text("Photographs to Use")
        } footer: {
            Footnote("No album chosen is the whole library; several are combined.")
        }
        .sheet(isPresented: $choosingAlbums) {
            AlbumPicker(model: model)
        }
        Section {
            HStack {
                Picker("Change photographs", selection: $model.preferences.subsetRenewal) {
                    Text("Never").tag(SubsetRenewal.never)
                    Text("Every Day").tag(SubsetRenewal.daily)
                    Text("Every Week").tag(SubsetRenewal.weekly)
                    Text("Every Month").tag(SubsetRenewal.monthly)
                }
                Button("Change Now", action: model.renewNow)
                    .disabled(model.isIndexing || !model.canRenew)
            }
        } footer: {
            Footnote(renewalNote)
        }
        Section {
            Toggle("Leave out screenshots, documents and weak photos", isOn: $model.preferences.leavesOutWeak)
                // One row of a grouped form (HIG, Toggles: mini switch).
                .controlSize(.mini)
        } footer: {
            Footnote(weakNote)
        }
    }

    private var weakNote: LocalizedStringKey {
        model.preferences.subsetRule == .uniformInTime
            ? "Receipts, notes and the like, and in each month the tenth of the photographs that Photos rates lowest. Others take their place."
            : "Receipts, notes and the like, and the tenth of the photographs that Photos rates lowest. Others take their place."
    }

    /// When the photographs last changed and next will, or what is under way.
    private var renewalNote: LocalizedStringKey {
        if model.isRenewing {
            return "Choosing new photographs. The screen saver shows the current ones until they are ready."
        }
        if model.preferences.subsetRule == .recent {
            return "The most recent photographs stay the same: a change picks other photographs only when they are random or spread over time."
        }
        let last = model.subsetRenewedAt.formatted(date: .abbreviated, time: .omitted)
        guard let next = model.nextRenewal else { return "Last changed on \(last)." }
        return "Last changed on \(last), next on \(next.formatted(date: .abbreviated, time: .omitted)). The screen saver shows the current photographs until the new ones are ready."
    }

    private func chooseAlbums() {
        choosingAlbums = true
    }

    /// Powers of two from 512: more than 8,192 adds time and disk, not
    /// variety. A size chosen before these existed stays on the list.
    private var sizes: [Int] {
        let presets = [512, 1_024, 2_048, 4_096, 8_192]
        let current = model.preferences.subsetSize
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }
}
