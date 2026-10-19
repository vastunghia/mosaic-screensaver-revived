import AppKit
import Darwin
import Metal
import MosaicCore
import MosaicEngine
import PhotoIndex
import QuartzCore
import ScreenSaver
import SharedStore
import os

/// M10: the screen saver. A thin shell over `MosaicEngine`, like the app's
/// player: it reads the index the app has built and the settings the app has
/// chosen, and nothing else. Without an index it says so and asks the app,
/// through `mosaic://update`, to make one.
///
/// It runs inside `legacyScreenSaver`, sandboxed, with that process's identity:
/// no Photos, no writing outside its container, and the unified log as its only
/// diagnostic channel (spikes 1 and 2). The process also outlives a run of the
/// saver and is reused by the next one (spike 4), so whatever a run builds it
/// lets go of when it stops.
@objc(MosaicSaverView)
final class MosaicSaverView: ScreenSaverView {
    nonisolated private static let log = Logger(subsystem: "com.vastunghia.Mosaic", category: "saver")

    /// The original would not start with fewer (SPEC § 5); nor does the app.
    nonisolated private static let minimumPhotographs = 100

    private var engine: MosaicEngine?
    private var closeUps: ShelvedPhotoSource?
    private var link: CADisplayLink?
    private var time: TimeInterval = 0
    private var lastTimestamp: CFTimeInterval?
    /// Bumped by every start and stop, so an engine that finishes building
    /// after its run has ended is dropped instead of shown.
    private var generation = 0
    private var isRunning = false
    private var everStarted = false
    private var willStopObserver: NSObjectProtocol?
    private var message: NSTextField?
    /// When the engine began drawing, for telling a preview nobody sees.
    private var beganAt: CFTimeInterval?
    /// While a preview nobody sees waits, without an engine, to be seen.
    private var probe: Timer?
    private static var created = 0
    private let instance: Int

    override init?(frame: NSRect, isPreview: Bool) {
        Self.created += 1
        instance = Self.created
        super.init(frame: frame, isPreview: isPreview)
        Self.instances.add(self)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.log.notice("""
            created #\(Self.created, privacy: .public), preview \(isPreview, privacy: .public), \
            \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public) points, \
            pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public), \
            footprint \(Self.footprintMB, privacy: .public) MB
            """)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override var isOpaque: Bool { true }

    // MARK: Life cycle

    override func startAnimation() {
        super.startAnimation()
        Self.log.notice("""
            startAnimation #\(self.instance, privacy: .public) of \(Self.created, privacy: .public): \
            window \(self.window == nil ? "none" : "yes", privacy: .public), \
            visible \(self.window?.isVisible ?? false, privacy: .public), \
            occlusion visible \(self.window?.occlusionState.contains(.visible) ?? false, privacy: .public), \
            on screen \(self.window?.screen?.localizedName ?? "none", privacy: .public), \
            window number \(self.window?.windowNumber ?? -1, privacy: .public), \
            superview \(self.superview == nil ? "none" : "yes", privacy: .public)
            """)
        guard !isRunning else { return }
        isRunning = true
        everStarted = true
        generation += 1
        let run = generation

        // On macOS 14 and later stopAnimation does not always arrive when the
        // saver is dismissed; this notification does.
        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.notice("screen saver will stop")
                self?.stop()
            }
        }

        let screen = window?.screen
        guard isPreview || screen == nil || screen == NSScreen.screens.first else {
            // One mosaic, on the main display, for now (SPEC § 10).
            Self.log.notice("not the main display: staying black")
            return
        }

        // legacyScreenSaver does not throw away the views of earlier runs: it
        // calls startAnimation on them again, about 20 ms before it creates
        // the new one, and they draw into windows nobody sees (three runs, three
        // engines, 2.1 GB; 2026-10-02). Their windows look exactly like the new
        // one's. What tells them apart is age: the newest view on a screen is
        // the one shown. So a view stops older ones as it starts, and waits a
        // moment before building, in case it is the old one.
        // Previews and the saver proper are told apart by kind: a preview
        // supersedes only older previews.
        for other in Self.instances.allObjects
        where other !== self && other.instance < instance && other.isPreview == isPreview
            && other.window?.screen == screen {
            other.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == run, self.isRunning else { return }
                if self.isSuperseded {
                    Self.log.notice("#\(self.instance, privacy: .public) is a leftover of an earlier run: not starting")
                    self.stop()
                    return
                }
                self.build(run: run, screen: screen)
            }
        }
    }

    /// System Settings does not always start the preview it shows: opened
    /// with Mosaic already chosen, it put the preview in its window and never
    /// called startAnimation, and the preview stayed black until another saver
    /// was chosen and Mosaic again (2026-10-07). So a preview that nobody has
    /// started a moment after it is placed starts itself — once: a stop after
    /// that, as when the options sheet opens, is meant.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isPreview, window != nil, !everStarted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unstartedPreviewWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, !self.everStarted,
                      !Self.instances.allObjects.contains(where: { $0.isPreview && $0.instance > self.instance })
                else { return }
                Self.log.notice("preview #\(self.instance, privacy: .public) placed but never started: starting it")
                self.startAnimation()
            }
        }
    }

    nonisolated private static let unstartedPreviewWait: TimeInterval = 1

    /// Long enough for the new view to be created after an old one was
    /// restarted (about 20 ms, measured), short beside the seconds the atlas
    /// takes.
    private static let startDelay: TimeInterval = 0.6

    private static let instances = NSHashTable<MosaicSaverView>.weakObjects()

    /// A newer view showing on this screen, or not placed yet.
    private var isSuperseded: Bool {
        Self.instances.allObjects.contains { other in
            other.instance > instance && other.isPreview == isPreview
                && (other.window == nil || other.window?.screen == window?.screen)
        }
    }

    private func build(run: Int, screen: NSScreen?) {
        let seed = UInt64.random(in: .min ... .max)
        let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
        let started = ProcessInfo.processInfo.systemUptime
        let preview = isPreview
        Self.log.notice("starting\(preview ? " the preview" : "", privacy: .public), seed \(String(seed, radix: 16), privacy: .public)")

        // Reading the index and building the atlas take seconds: off the main
        // thread, which belongs to legacyScreenSaver and its events.
        let box = Built()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                (box.engine, box.closeUps) = try Self.makeEngine(seed: seed, display: display, preview: preview)
            } catch {
                box.failure = error
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == run, self.isRunning else {
                        Self.log.notice("an engine built for a run that has ended was dropped")
                        return
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    if let engine = box.engine {
                        Self.log.notice("""
                            engine ready in \(elapsed, format: .fixed(precision: 2), privacy: .public) s \
                            on \(engine.deviceName, privacy: .public), \
                            footprint \(Self.footprintMB, privacy: .public) MB
                            """)
                        self.closeUps = box.closeUps
                        self.begin(engine, display: display)
                    } else {
                        let failure = box.failure.map { "\($0)" } ?? "unknown"
                        Self.log.error("no engine: \(failure, privacy: .public)")
                        self.show(Self.explanation(of: box.failure))
                        if !preview, let reason = Self.updateReason(for: box.failure) {
                            Self.askForUpdate(reason: reason)
                        }
                    }
                }
            }
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        stop()
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        link?.invalidate()
        link = nil
        if let willStopObserver {
            DistributedNotificationCenter.default().removeObserver(willStopObserver)
        }
        willStopObserver = nil
        let cycle = engine?.statistics.cycleIndex
        // A cycle planned without the index, on the fallback: its files went
        // missing under it, which the app's housekeeping must never cause.
        if let error = engine?.statistics.lastError {
            Self.log.error("a cycle fell back to the stand-in mosaic: \(error, privacy: .public)")
        }
        if let closeUps {
            Self.log.notice("""
                close-ups: \(closeUps.served, privacy: .public) from the shelf, \
                \(closeUps.fallbacks, privacy: .public) from thumbnails for want of one
                """)
        }
        probe?.invalidate()
        probe = nil
        beganAt = nil
        engine = nil
        closeUps = nil
        lastTimestamp = nil
        time = 0
        Self.log.notice("""
            stopped at cycle \(cycle.map(String.init) ?? "none", privacy: .public), \
            footprint \(Self.footprintMB, privacy: .public) MB
            """)
    }

    // MARK: The engine

    /// The preview is the effect itself, on fewer photographs: the atlas is
    /// what costs, and in a window a few hundred points wide 256 photographs
    /// look like 2048. It lives as long as System Settings shows it, in a
    /// process of its own, also while the saver runs (spike 1).
    nonisolated private static let previewPoolSize = 256

    nonisolated private static func makeEngine(
        seed: UInt64, display: CGDirectDisplayID?, preview: Bool
    ) throws -> (MosaicEngine, ShelvedPhotoSource?) {
        let store = PhotoIndexStore(directory: SharedLocations.indexDirectory)
        let index = try IndexedPhotoSource(store: store)
        guard index.entries.count >= minimumPhotographs else {
            throw SaverError.tooFewPhotographs(index.entries.count)
        }
        let shared = SharedSettings.read()
        let chosen = shared ?? .standard
        let settings = MosaicSettings(rows: chosen.rows, cycleDuration: chosen.cycleDuration)
        let pool = index.pool(size: preview ? previewPoolSize : MosaicEngine.maximumPoolSize, seed: seed)
        let planner = SolvedMosaicPlanner(catalog: IndexedTileCatalog(source: pool), seed: seed)
        log.notice("""
            \(chosen.rows, privacy: .public) rows, \(chosen.cycleDuration, format: .fixed(precision: 0), privacy: .public) s a cycle\
            \(shared == nil ? " (standard: no settings from the app)" : "", privacy: .public)
            """)

        // The GPU driving the display: with an eGPU attached, the system
        // default is not necessarily it.
        guard let device = display.flatMap(CGDirectDisplayCopyCurrentMetalDevice)
            ?? MTLCreateSystemDefaultDevice()
        else {
            throw SaverError.noMetalDevice
        }
        log.notice("""
            \(pool.entries.count, privacy: .public) of \(index.entries.count, privacy: .public) photographs, \
            system default GPU \(MTLCreateSystemDefaultDevice()?.name ?? "none", privacy: .public), \
            display's GPU \(device.name, privacy: .public)
            """)
        guard !preview else {
            // Nothing in a preview grows past a slice of the atlas.
            let engine = try MosaicEngine(device: device, settings: settings, source: pool, planner: planner, seed: seed)
            return (engine, nil)
        }
        // No originals here: the close-ups come from the shelf the app
        // stocks, and from the thumbnails where it has a gap.
        let shelf = CloseUpShelf(
            directory: SharedLocations.closeUpDirectory, width: CloseUpOptions.standard.anchorWidth ?? 1920
        )
        let onShelf = pool.entries.count { shelf.has($0) }
        log.notice("\(onShelf, privacy: .public) of the pool's \(pool.entries.count, privacy: .public) close-ups on the shelf")
        let closeUps = ShelvedPhotoSource(index: pool, shelf: shelf)
        let engine = try MosaicEngine(
            device: device,
            settings: settings,
            source: pool,
            planner: planner,
            seed: seed,
            closeUpSource: closeUps
        )
        return (engine, closeUps)
    }

    private func begin(_ engine: MosaicEngine, display: CGDirectDisplayID?) {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        self.engine = engine
        message?.removeFromSuperview()
        engine.attach(to: metalLayer, size: drawableSize())
        if let fps = window?.screen?.maximumFramesPerSecond, fps > 0 {
            engine.refreshInterval = 1.0 / Double(fps)
        }
        if let display {
            engine.deviceProvider = { _ in CGDirectDisplayCopyCurrentMetalDevice(display) }
        }
        // A display link tied to this view follows the refresh of the screen
        // it is on, as in the app; animateOneFrame is a timer.
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        beganAt = CACurrentMediaTime()
    }

    // MARK: A preview nobody sees

    /// System Settings can start the preview, or start it again, where nobody
    /// sees it — after the screen saver has run over it, or with its window
    /// gone — and never stop it: one drew for two hours, 1,500 frames a cycle
    /// and none of them shown (2026-10-07). Window occlusion cannot tell: a
    /// preview in plain view reported itself occluded. Whether frames reach
    /// the screen can — not whether one does: a preview behind other windows
    /// had a frame shown every five seconds. So a preview that shows fewer
    /// than one frame in ten for `unseenLimit` lets its engine go, and every
    /// `probeInterval` presents a burst of blank frames: most of them shown,
    /// and it builds its engine again.
    private static let unseenLimit: TimeInterval = 5
    private static let probeInterval: TimeInterval = 2
    nonisolated private static let probeBurst = 10
    nonisolated private static let probeShownToWake = 8

    /// One in ten of the frames the display would show in `unseenLimit`.
    private var fewestSeenFrames: Int {
        let fps = window?.screen?.maximumFramesPerSecond ?? 60
        return max(1, Int(Self.unseenLimit) * max(fps, 1) / 10)
    }

    private func hibernate(device: MTLDevice) {
        let shown = engine?.framesPresented(within: Self.unseenLimit) ?? 0
        Self.log.notice("""
            preview #\(self.instance, privacy: .public) showed \(shown, privacy: .public) frames in \
            \(Self.unseenLimit, format: .fixed(precision: 0), privacy: .public) s: nobody sees it, letting its engine go
            """)
        link?.invalidate()
        link = nil
        engine = nil
        beganAt = nil
        lastTimestamp = nil
        guard let metalLayer = layer as? CAMetalLayer, let queue = device.makeCommandQueue() else { return }
        let run = generation
        let target = ProbeTarget(layer: metalLayer)
        probe = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
            // Blank frames, one a refresh, from another thread: nextDrawable
            // may wait.
            DispatchQueue.global(qos: .utility).async {
                let tally = ProbeTally()
                for _ in 0..<Self.probeBurst {
                    guard let drawable = target.layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = drawable.texture
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
                    drawable.addPresentedHandler { frame in
                        guard tally.count(shown: frame.presentedTime > 0) == Self.probeShownToWake else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.wake(run: run) }
                        }
                    }
                    commands.present(drawable, afterMinimumDuration: 1.0 / 60)
                    commands.commit()
                }
            }
        }
    }

    private func wake(run: Int) {
        guard probe != nil, generation == run, isRunning else { return }
        probe?.invalidate()
        probe = nil
        Self.log.notice("preview #\(self.instance, privacy: .public) is shown again: building its engine")
        build(run: run, screen: window?.screen)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        MainActor.assumeIsolated {
            guard let engine else { return }
            if isPreview, let beganAt, now - beganAt > Self.unseenLimit,
               engine.framesPresented(within: Self.unseenLimit) < fewestSeenFrames {
                hibernate(device: engine.device)
                return
            }
            let delta = lastTimestamp.map { now - $0 } ?? 0
            // The clock holds while the engine is not ready for the instant it
            // would move to, exactly as the app's does: a pause at a join, never
            // a frame drawn wrong.
            let next = time + min(delta, 0.25)
            guard engine.isReady(at: next) else {
                lastTimestamp = nil
                if engine.isReady(at: time) { engine.advance(to: time) }
                return
            }
            time = next
            lastTimestamp = now
            engine.advance(to: time)
        }
    }

    override func animateOneFrame() {}

    // MARK: Geometry

    private func drawableSize() -> CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        engine?.resize(drawableSize())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        engine?.resize(drawableSize())
    }

    // MARK: Options

    /// Settings live in the app (milestone 5): the sheet says what the saver
    /// will show, and opens the app to change it.
    override var hasConfigureSheet: Bool { true }

    private var optionsSheet: NSWindow?

    override var configureSheet: NSWindow? {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let title = NSTextField(labelWithString: "Mosaic")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let status = NSTextField(wrappingLabelWithString: Self.indexStatus())
        let settings = SharedSettings.read() ?? .standard
        let effect = NSTextField(wrappingLabelWithString: String(
            localized: "\(settings.rows) rows, \(Int(settings.cycleDuration)) seconds a photograph.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
            comment: "Screen saver options: the two settings of the effect"))
        let note = NSTextField(wrappingLabelWithString: String(
            localized: "The photographs and the settings are chosen in Mosaic Companion.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
            comment: "Screen saver options"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let open = NSButton(title: String(localized: "Open Mosaic Companion…", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                                          comment: "Screen saver options: button"),
                            target: self, action: #selector(openApp(_:)))
        let done = NSButton(title: String(localized: "Done", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale, comment: "Screen saver options: button that closes them"),
                            target: self, action: #selector(closeOptions(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [open, NSView(), done])
        buttons.distribution = .fill

        let stack = NSStackView(views: [title, status, effect, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(18, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 400),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        sheet.contentView = content
        optionsSheet = sheet
        return sheet
    }

    /// What the index holds, read now: the app may have changed it since the
    /// saver last ran.
    private static func indexStatus() -> String {
        let store = PhotoIndexStore(directory: SharedLocations.indexDirectory)
        guard let manifest = try? store.load(), !manifest.entries.isEmpty else {
            return String(localized: "No photographs yet. Open Mosaic Companion to choose them.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                          comment: "Screen saver options: the status, before there is an index")
        }
        let count = manifest.entries.count
        let needed = minimumPhotographs
        guard let date = try? store.manifestURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else {
            return count < needed
                ? String(localized: "\(count) photographs: Mosaic needs at least \(needed).", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                         comment: "Screen saver options: the status, with too few photographs")
                : String(localized: "\(count) photographs.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale, comment: "Screen saver options: the status")
        }
        let updated = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: SaverLanguage.locale))
        return count < needed
            ? String(localized: "\(count) photographs, updated \(updated): Mosaic needs at least \(needed).", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                     comment: "Screen saver options: the status, with when the photographs last changed, and too few of them")
            : String(localized: "\(count) photographs, updated \(updated).", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                     comment: "Screen saver options: the status, with when the photographs last changed")
    }

    @objc private func openApp(_ sender: Any?) {
        let opened = NSWorkspace.shared.open(MosaicURL.open.url)
        Self.log.notice("options: opened the app, \(opened ? "done" : "failed", privacy: .public)")
        closeOptions(sender)
    }

    @objc private func closeOptions(_ sender: Any?) {
        guard let sheet = optionsSheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.close()
        }
        optionsSheet = nil
    }

    // MARK: Messages

    private func show(_ text: String) {
        message?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = NSColor(white: 0.75, alpha: 1)
        label.font = .systemFont(ofSize: isPreview ? 9 : 20)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
        message = label
    }

    /// Why the app should be called, if it can help: only for an index that
    /// is missing or too small. Keeping an index fresh is the login item's
    /// job, not the saver's (spike 4): a saver that started PhotoKit work on
    /// every run would compete with itself.
    private static func updateReason(for error: Error?) -> String? {
        switch error {
        case PhotoIndexError.missing?: return "index-missing"
        case SaverError.tooFewPhotographs?: return "too-few-photographs"
        default: return nil
        }
    }

    /// The process outlives a run (spike 4), so this spans runs: at most one
    /// call an hour, whatever the app makes of it.
    private static var lastUpdateCall: TimeInterval?
    private static let updateCallInterval: TimeInterval = 3600

    private static func askForUpdate(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastUpdateCall, now - lastUpdateCall < updateCallInterval {
            log.notice("not calling the app again so soon (\(reason, privacy: .public))")
            return
        }
        lastUpdateCall = now
        // A URL, not arguments, which are dropped on the way out of
        // legacyScreenSaver; and the app is launched with its own Photos grant.
        let url = MosaicURL.update(reason: reason).url
        let opened = NSWorkspace.shared.open(url)
        log.notice("called the app with \(url, privacy: .public): \(opened ? "opened" : "failed", privacy: .public)")
    }

    private static func explanation(of error: Error?) -> String {
        switch error {
        case PhotoIndexError.missing?:
            return String(localized: "Open Mosaic Companion to choose the photographs for the screen saver.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                          comment: "Shown on the screen saver, when there is no index")
        case SaverError.tooFewPhotographs(let count)?:
            return String(localized: "Mosaic has \(count) photographs so far. Open Mosaic Companion to add more.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                          comment: "Shown on the screen saver, with too few photographs to start")
        default:
            return String(localized: "Mosaic could not start. Open Mosaic Companion to check its photographs.", bundle: SaverLanguage.bundle, locale: SaverLanguage.locale,
                          comment: "Shown on the screen saver, when it fails")
        }
    }

    /// The process's physical footprint, which is what Activity Monitor shows:
    /// legacyScreenSaver is reused from one run to the next, so a run that
    /// leaves memory behind shows up here, run after run.
    private static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

enum SaverError: Error {
    case tooFewPhotographs(Int)
    case noMetalDevice
}

/// The engine, carried from the thread that built it to the main thread.
private final class Built: @unchecked Sendable {
    var engine: MosaicEngine?
    var closeUps: ShelvedPhotoSource?
    var failure: Error?
}

/// The layer the probe draws into from a background thread: nextDrawable is
/// safe to call off the main thread, which the compiler cannot know.
private final class ProbeTarget: @unchecked Sendable {
    let layer: CAMetalLayer
    init(layer: CAMetalLayer) { self.layer = layer }
}

/// Shown frames of one probe burst, counted from Metal's handler threads.
private final class ProbeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0

    /// The number shown so far, this frame included.
    func count(shown frameShown: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if frameShown { shown += 1 }
        return shown
    }
}
