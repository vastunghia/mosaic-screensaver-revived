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
        .frame(width: 560, height: 480)
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
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding([.horizontal, .top], 24)
    }

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
                Footnote("This matters only if your Photos library keeps its originals in iCloud. Then Mosaic Companion can download a sharp copy of the photographs it shows full screen, about 1.3 MB each, never the original: at most \(DownloadLedger.standardDailyLimit) a day and \(DownloadLedger.standardWeeklyLimit) a week, and none on a hotspot or in Low Data Mode. With Nothing, Mosaic Companion tells you in its window if some close-ups turn out blurry. You can change this in Settings.")
            }
        case .updates:
            Section {
                NotificationsRow(model: model)
            } footer: {
                Footnote("Mosaic Companion checks for a new version once a day. Allow notifications so that it can tell you when one is ready, even if you never open its window: they are used for nothing else. You can change this in Settings.")
            }
        case .done:
            Section {
                ForEach(SetupPage.pages(for: model), id: \.self) { page in
                    if let done = page.isDone(model) {
                        Label {
                            Text(page.title)
                        } icon: {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        }
                        .accessibilityValue(done ? String(localized: "Done", comment: "Setup summary, VoiceOver: this page's step is done")
                                                 : String(localized: "Not done", comment: "Setup summary, VoiceOver: this page's step is not done"))
                    }
                }
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
