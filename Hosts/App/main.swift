import AppKit
import Metal
import MosaicEngine
import MosaicPhotos
import PhotoIndex
import SwiftUI

// M9, in its milestone-2 form: a window for judging the effect, an offscreen
// mode for looking at it cold, and a way to build the index the photographs come
// from.
//
// Everything of substance is behind MosaicEngine. If this file ever grows a
// shortcut the .saver could not take, that is an architecture bug, not a
// convenience.

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

do {
    // Indexing needs no GPU, so it happens before we go looking for one.
    if options.buildIndex {
        guard let folder = options.folder else {
            throw HarnessError.indexingWithoutAFolder
        }
        let source = try FolderPhotoSource(root: folder)
        print("mosaic: indexing \(source.root.path)")
        try PhotoSourceFactory.buildIndex(
            folder: source,
            store: PhotoIndexStore(directory: options.resolvedIndexDirectory),
            root: source.root.path,
            options: options
        )
        exit(0)
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
                + options.batchTolerances.map(BatchExporter.Column.tolerance),
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
        try CycleExporter.export(
            to: directory,
            frames: options.exportFrames,
            width: options.exportWidth,
            settings: options.settings,
            startCycle: options.exportCycle,
            device: device,
            library: library,
            source: photos.source,
            planner: planning.planner,
            tileWidth: options.tileWidth,
            seed: options.seed
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
        tilePixelWidth: options.tileWidth
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
