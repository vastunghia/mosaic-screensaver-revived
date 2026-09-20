import AppKit
import Metal
import MosaicEngine
import SwiftUI

// M9, in its milestone-1 form: a window for judging the movement, and an
// offscreen mode for looking at it cold.
//
// Everything of substance is behind MosaicEngine. If this file ever grows a
// shortcut the .saver could not take, that is an architecture bug, not a
// convenience.

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("\(HarnessError.noMetalDevice)\n".utf8))
    exit(1)
}

do {
    let library = try ShaderLibrary.load(device: device)

    if let directory = options.exportDirectory {
        try CycleExporter.export(
            to: directory,
            frames: options.exportFrames,
            width: options.exportWidth,
            settings: options.settings,
            startCycle: options.exportCycle,
            device: device,
            library: library,
            poolSize: options.poolSize
        )
        exit(0)
    }

    let engine = try MosaicEngine(
        device: device,
        settings: options.settings,
        source: SyntheticPhotoSourceFactory.make(count: options.poolSize),
        library: library
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
