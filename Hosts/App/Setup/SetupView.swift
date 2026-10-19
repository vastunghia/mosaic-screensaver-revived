import PhotoIndex
import SwiftUI

/// The setup, a page at a time, in a window of its own: what the screen saver
/// needs, then what keeps it current. Continue never waits for an answer: a
/// page skipped shows up again in the window's status.
struct SetupView: View {
    @ObservedObject var model: AppModel
    /// The last page's button, and only it, marks the setup done.
    let finish: () -> Void
    @State private var page = SetupPage.welcome

    var body: some View {
        let pages = SetupPage.pages(for: model)
        let index = pages.firstIndex(of: page) ?? 0
        VStack(spacing: 0) {
            header
            Form {
                content
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Divider()
            HStack {
                indicator(index: index, of: pages.count)
                Spacer()
                if index > 0 {
                    Button("Back", action: back)
                }
                // "Get Started" opens the flow and "Done" closes it (HIG,
                // Writing: consistent language through multiple steps).
                if page == .done {
                    Button("Done", action: finish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(page == .welcome ? String(localized: "Get Started", comment: "Setup: the first page's button")
                                            : String(localized: "Continue", comment: "Setup: the button to the next page"),
                           action: next)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 380)
    }

    // MARK: Pages

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            if page.isDone(model) == true {
                Label(Self.stepDone, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding([.horizontal, .top], 24)
    }

    /// What a page says when what it asks for is in place, beside its title
    /// and to VoiceOver. A key of its own, though English says "Done" for both:
    /// the button that ends the setup is an action ("Fine" in Italian), this is
    /// a state ("Fatto").
    private static let stepDone = String(localized: "Step done", defaultValue: "Done",
                                         comment: "Setup: beside a page's title, and in the summary, when what the page asks for is in place; a state, not a button")

    /// The last page does not claim everything is done when it is not.
    private var title: String {
        guard page == .done else { return page.title }
        let undone = SetupPage.pages(for: model).contains { $0.isDone(model) == false }
        guard undone else { return page.title }
        return String(localized: "Almost Done", comment: "Setup: last page's title, when some page asked for something not done")
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome:
            Section {
                Text("Mosaic turns your photographs into an endless zoom: every photograph turns out to be one tile of a mosaic, which makes up another photograph, which is one tile of the next mosaic.")
                Text("Mosaic is a screen saver. Mosaic Companion, this app, prepares your photographs for it and keeps its settings. These pages set it up; you can come back to them at any time from the Mosaic Companion menu, with Set Up Mosaic.")
                    .foregroundStyle(.secondary)
            }
        case .location:
            Section {
                LocationRow(model: model)
                ProblemRow(model: model, place: .location)
            } footer: {
                Footnote("It opens again from there. The screen saver and the login item need it to stay in one place; the downloaded copy can then go in the Bin.")
            }
        case .photographs:
            Section {
                Picker("Photographs from", selection: $model.preferences.source) {
                    Text("Photos library").tag(AppPreferences.Source.photos)
                    Text("A folder").tag(AppPreferences.Source.folder)
                }
                .pickerStyle(.segmented)
                if model.preferences.source == .photos {
                    PhotosAccessRow(model: model)
                } else {
                    FolderRow(model: model)
                }
                ProblemRow(model: model, place: .photographs)
            } footer: {
                Footnote("They never leave this Mac: Mosaic Companion keeps a small copy of each, to build the mosaics from. Which albums, and how many photographs, are in Settings.")
            }
        case .screenSaver:
            Section {
                switch model.saver {
                case .installed:
                    Text("Screen saver installed")
                default:
                    SaverRow(model: model, showingSettings: false)
                }
                ProblemRow(model: model, place: .screenSaver)
            } footer: {
                Footnote("Mosaic Companion carries the screen saver and installs it for you. At the end of the setup you choose it in System Settings.")
            }
        case .background:
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { model.opensAtLogin },
                    set: { model.setOpensAtLogin($0) }
                ))
                .controlSize(.mini)
                .disabled(model.isTranslocated)
                if model.loginItem == .requiresApproval {
                    HStack {
                        Text("Waiting for approval in System Settings")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…", action: model.openLoginItemsSettings)
                    }
                }
                ProblemRow(model: model, place: .background)
            } footer: {
                Footnote("Mosaic Companion keeps the screen saver’s photographs up to date only while it runs. At login it opens without a window and stays in the background, so new photographs reach the screen saver without your opening it. You can change this in its window.")
            }
        case .downloads:
            Section {
                Picker("Download from iCloud", selection: Binding(
                    get: { model.preferences.downloads ?? .nothing },
                    set: { model.answerAboutDownloads($0) }
                )) {
                    Text("Nothing").tag(AppPreferences.Downloads.nothing)
                    Text("Sharp close-ups only").tag(AppPreferences.Downloads.closeUps)
                    // Not offered here: originals can weigh gigabytes. Shown
                    // only to someone who already chose it in Settings.
                    if model.preferences.downloads == .everything {
                        Text("Everything needed").tag(AppPreferences.Downloads.everything)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                // Three paragraphs: as one block of six lines it went unread.
                VStack(alignment: .leading, spacing: 8) {
                    Footnote("This matters only if your Photos library keeps its originals in iCloud.")
                    Footnote("Then Mosaic Companion can download a sharp copy of the photographs it shows full screen, about 1.3 MB each, never the original: at most \(DownloadLedger.standardDailyLimit) a day and \(DownloadLedger.standardWeeklyLimit) a week, and none on a hotspot or in Low Data Mode.")
                    Footnote("With Nothing, Mosaic Companion tells you in its window if some close-ups turn out blurry. You can change this in Settings.")
                }
            }
        case .updates:
            Section {
                NotificationsRow(model: model)
            } footer: {
                Footnote("Mosaic Companion checks for a new version once a day. Allow notifications so that it can tell you when one is ready, even if you never open its window: they are used for nothing else. You can change this in Settings.")
            }
        case .done:
            Section {
                summary
            } footer: {
                Footnote("What is left undone stays in the Mosaic Companion window, with what to do about it.")
            }
            if model.saver == .installed {
                Section {
                    HStack {
                        Text("Choose Mosaic under \(SaverInstaller.whereToChoose).")
                        Spacer()
                        Button("Open Screen Saver Settings…", action: model.openScreenSaverSettings)
                    }
                }
            }
        }
    }

    /// Every step and whether it is done, in two columns: the window keeps
    /// one height for every page, and as a list this page alone set it.
    private var summary: some View {
        let steps = SetupPage.pages(for: model).compactMap { page in page.isDone(model).map { (page, $0) } }
        let half = (steps.count + 1) / 2
        return HStack(alignment: .top, spacing: 0) {
            summaryColumn(steps[..<half])
            summaryColumn(steps[half...])
        }
    }

    private func summaryColumn(_ steps: ArraySlice<(SetupPage, Bool)>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps, id: \.0) { page, done in
                Label {
                    Text(page.title)
                } icon: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .accessibilityValue(done ? Self.stepDone
                                         : String(localized: "Not done", comment: "Setup summary, VoiceOver: this page's step is not done"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The pages are worked out when a button acts, not when it is drawn:
    // Return keeps the action of the first Continue it was bound to, and with
    // the pages captured then it went back to the second page from any other.

    /// Leaving the downloads page unanswered is the answer Nothing: the window
    /// advises otherwise if it turns out to matter.
    private func next() {
        let pages = SetupPage.pages(for: model)
        guard let index = pages.firstIndex(of: page), index + 1 < pages.count else { return }
        if page == .downloads, model.preferences.downloads == nil {
            model.answerAboutDownloads(.nothing)
        }
        page = pages[index + 1]
    }

    private func back() {
        let pages = SetupPage.pages(for: model)
        guard let index = pages.firstIndex(of: page), index > 0 else { return }
        page = pages[index - 1]
    }

    private func indicator(index: Int, of count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(dot == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}
