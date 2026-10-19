import AppKit
import Metal
import MosaicEngine
import MosaicPhotos
import PhotoIndex
import ServiceManagement
import SwiftUI

// M9, in its milestone-2 form: a window for judging the effect, an offscreen
// mode for looking at it cold, and a way to build the index the photographs come
// from.
//
// Everything of substance is behind MosaicEngine. If this file ever grows a
// shortcut the .saver could not take, that is an architecture bug, not a
// convenience.

// For scripts/uninstall.sh: the login item outlives the app it opens, and only
// the app can take its own registration back.
if CommandLine.arguments.dropFirst().first == "--unregister-login-item" {
    let before = SMAppService.mainApp.status
    do {
        try SMAppService.mainApp.unregister()
        print("mosaic: login item unregistered")
        exit(0)
    } catch where before != .enabled && before != .requiresApproval {
        print("mosaic: no login item to unregister")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("mosaic: login item not unregistered: \(error)\n".utf8))
        exit(1)
    }
}

if !MosaicApplication.wantsHarness(CommandLine.arguments) {
    MosaicApplication.run()
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

do {
    // Indexing needs no GPU, so it happens before we go looking for one.
    if options.buildIndex {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.indexingWithoutAFolder
        }
        // Off the main thread, as in the app: a fetch with a deadline is an
        // asynchronous request, and PhotoKit may answer it on the main queue.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("mosaic: indexing \(indexable.root)")
                let store = PhotoIndexStore(directory: options.resolvedIndexDirectory)
                try PhotoSourceFactory.buildIndex(
                    source: indexable.source, store: store, root: indexable.root, options: options
                )
                // What the app does after every build: the .saver's close-ups.
                if options.indexOnly { exit(0) }
                try PhotoSourceFactory.stockCloseUps(
                    source: indexable.source, store: store, shelf: options.closeUpShelf,
                    fetching: try options.closeUpFetching(store: store)
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    if let file = options.listPhotos {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        // What a subset rule chose, with dates: a specimen of rules is judged
        // on which years it draws from as much as on its mosaics.
        let dates = ISO8601DateFormatter()
        let lines = try indexable.source.photos().map { photo in
            "\"\(photo.id.rawValue)\",\(photo.creationDate.map(dates.string(from:)) ?? "")"
        }
        try (["id,created"] + lines).joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        print("mosaic: \(lines.count) photographs of \(indexable.name) listed in \(file.path)")
        exit(0)
    }

    if let directory = options.exportFaces {
        guard let folder = options.folder else { throw HarnessError.facesWithoutAFolder }
        let widths = options.resolvedFaceWidths
        let source = try FolderPhotoSource(root: folder)
        try FaceSpecimen.export(from: source, to: directory, widths: widths)
        exit(0)
    }

    if let count = options.verifyWindows {
        guard let indexed = try PhotoSourceFactory.make(options: options).indexed else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        let passed = try WindowVerifier.verify(indexed, count: count, width: options.closeUpOptions.anchorWidth ?? 1920)
        exit(passed ? 0 : 1)
    }

    if let count = options.verifyCanonical {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        let passed = try CanonicalVerifier.verify(
            indexable.source, name: indexable.name, count: count,
            width: options.thumbnailWidth, seed: options.seed
        )
        exit(passed ? 0 : 1)
    }

    if let count = options.probeLocal {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        try LocalProbe.probe(
            indexable.source, name: indexable.name, count: count, width: options.thumbnailWidth, seed: options.seed,
            csv: options.probeCSV
        )
        exit(0)
    }

    if let directory = options.exportCulling {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        let manifest = try PhotoIndexStore(directory: options.resolvedIndexDirectory).load()
        try CullingSpecimen.export(indexable.source, rule: options.subsetRule, manifest: manifest, to: directory)
        exit(0)
    }

    if let count = options.probeQuality {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        try QualityProbe.probe(
            indexable.source, name: indexable.name, count: count, width: options.thumbnailWidth, seed: options.seed,
            serial: options.probeSerial, csv: options.probeCSV
        )
        exit(0)
    }

    if let count = options.probeDownload {
        guard let indexable = try PhotoSourceFactory.indexable(options: options) else {
            throw HarnessError.verifyingWithoutPhotographs
        }
        try DownloadProbe.probe(
            index: PhotoIndexStore(directory: options.resolvedIndexDirectory), source: indexable.source,
            count: count, width: options.closeUpOptions.anchorWidth ?? 1920, seed: options.seed
        )
        exit(0)
    }

    if options.play {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let screen = options.screen.flatMap { name in
            NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
        }
        if let name = options.screen, screen == nil {
            throw HarnessError.unknownScreen(name, known: NSScreen.screens.map(\.localizedName))
        }
        try MainActor.assumeIsolated {
            try Player.play(options: options, on: screen) { NSApp.terminate(nil) }
        }
        if let seconds = options.quitAfter {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
        application.activate(ignoringOtherApps: true)
        application.run()
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw HarnessError.noMetalDevice
    }
    let library = try ShaderLibrary.load(device: device)
    let photos = try PhotoSourceFactory.make(options: options)
    let planning = PlannerFactory.make(options: options, photos: photos)
    print(options.banner(sourceDescription: photos.description))
    for note in planning.notes { print("  \(note)") }

    if let directory = options.exportBatch {
        try BatchExporter.export(
            to: directory,
            subjects: options.batchSubjects,
            firstCycle: options.exportCycle,
            columns: options.batchPenalties.map(BatchExporter.Column.penalty)
                + (options.batchComparesRing
                    ? options.batchTolerances.flatMap { [.ring($0, sharp: false), .ring($0, sharp: true)] }
                    : options.batchTolerances.map(BatchExporter.Column.tolerance)),
            width: options.exportWidth,
            options: options,
            device: device,
            library: library,
            photos: photos
        )
        exit(0)
    }

    if let file = options.exportMosaic {
        try MosaicExporter.export(
            to: file,
            cycle: options.exportCycle,
            width: options.exportWidth,
            settings: options.settings,
            device: device,
            library: library,
            photos: photos,
            planner: planning.planner,
            tileWidth: options.tileWidth,
            seed: options.seed
        )
        exit(0)
    }

    if let directory = options.exportDirectory {
        // A loop that did not take would export cycles that do not close:
        // nothing at all is the honest result.
        guard options.loop.isEmpty || planning.planner is LoopingPlanner else {
            print("error: --loop was not usable (see the warning above); nothing exported")
            exit(1)
        }
        try CycleExporter.export(
            to: directory,
            frames: options.exportFrames,
            width: options.exportWidth,
            settings: options.settings,
            // One round of a loop, from the first cycle whose subject has one
            // before it: cycle 0 has no anchor.
            startCycle: options.loop.isEmpty ? options.exportCycle : options.loop.count,
            cycles: max(1, options.loop.count),
            closing: !options.loop.isEmpty,
            device: device,
            library: library,
            source: photos.source,
            planner: planning.planner,
            tileWidth: options.tileWidth,
            seed: options.seed,
            closeUpSource: PhotoSourceFactory.closeUpSource(options.closeUps, photos: photos, shelf: options.closeUpShelf),
            closeUpOptions: options.closeUpOptions
        )
        exit(0)
    }

    let engine = try MosaicEngine(
        device: device,
        settings: options.settings,
        source: photos.source,
        planner: planning.planner,
        library: library,
        seed: options.seed,
        tilePixelWidth: options.tileWidth,
        closeUpSource: PhotoSourceFactory.closeUpSource(options.closeUps, photos: photos, shelf: options.closeUpShelf),
        closeUpOptions: options.closeUpOptions
    )

    let application = NSApplication.shared
    let delegate = HarnessDelegate(engine: engine, options: options)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
