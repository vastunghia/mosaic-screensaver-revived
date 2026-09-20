import Foundation
import MosaicCore
import MosaicPhotos

/// Command line options. Deliberately tiny: this is a development harness, and
/// anything worth keeping ends up in the preferences of the real app instead.
struct Options {
    var rows = 20
    var cycleDuration: Double = 20
    var crossfadeDuration: Double = 0.15
    var poolSize = 256
    var exportDirectory: URL?
    var exportFrames = 240
    var exportWidth = 1280
    var exportCycle = 1
    var fullScreen = false

    var settings: MosaicSettings {
        MosaicSettings(
            rows: rows,
            cycleDuration: cycleDuration,
            crossfadeDuration: crossfadeDuration
        )
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0

        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }

        while index < arguments.count {
            switch arguments[index] {
            case "--rows": options.rows = next().flatMap(Int.init) ?? options.rows
            case "--duration": options.cycleDuration = next().flatMap(Double.init) ?? options.cycleDuration
            case "--crossfade": options.crossfadeDuration = next().flatMap(Double.init) ?? options.crossfadeDuration
            case "--pool": options.poolSize = next().flatMap(Int.init) ?? options.poolSize
            case "--export-cycle": options.exportDirectory = next().map { URL(fileURLWithPath: $0) }
            case "--frames": options.exportFrames = next().flatMap(Int.init) ?? options.exportFrames
            case "--width": options.exportWidth = next().flatMap(Int.init) ?? options.exportWidth
            case "--cycle": options.exportCycle = next().flatMap(Int.init) ?? options.exportCycle
            case "--full-screen": options.fullScreen = true
            default: break
            }
            index += 1
        }

        return options
    }
}

/// The synthetic source is built in one place so the window and the exporter
/// cannot drift apart and render different pools.
enum SyntheticPhotoSourceFactory {
    static func make(count: Int) -> SyntheticPhotoSource {
        SyntheticPhotoSource(count: count)
    }
}
