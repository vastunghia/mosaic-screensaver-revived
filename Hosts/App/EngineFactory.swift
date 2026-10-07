import Metal
import MosaicEngine
import PhotoIndex

/// The engine for a set of options: the photographs, the planner and the
/// close-ups they name, on one device. Full screen and in the window's
/// preview alike, so the preview is the effect and not an imitation of it.
enum EngineFactory {
    static func make(options: Options, device: MTLDevice) throws -> MosaicEngine {
        let library = try ShaderLibrary.load(device: device)
        let photos = try PhotoSourceFactory.make(options: options)
        let planning = PlannerFactory.make(options: options, photos: photos)
        print(options.banner(sourceDescription: photos.description))

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
        engine.holdsEachFrameOneRefresh = options.holdsEachFrameOneRefresh
        return engine
    }

    /// The window's preview: the index as it is on disk, and nothing else, as
    /// the screen saver's preview reads it. Not through
    /// `PhotoSourceFactory.make`, which brings a library's index up to date
    /// first: that took 2.9 s at every start, and wrote the index while the
    /// app's own pass might be writing it too (2026-10-07). No close-ups, and
    /// the pool is `options.poolSize`.
    static func makePreview(options: Options, device: MTLDevice) throws -> MosaicEngine {
        let library = try ShaderLibrary.load(device: device)
        let full = try IndexedPhotoSource(store: PhotoIndexStore(directory: options.resolvedIndexDirectory))
        let pool = full.pool(size: min(options.poolSize, MosaicEngine.maximumPoolSize), seed: options.seed)
        let photos = PhotoSourceFactory.Resolved(
            source: pool, description: "\(pool.entries.count) of \(full.entries.count) indexed photographs", indexed: pool
        )
        let planning = PlannerFactory.make(options: options, photos: photos)
        return try MosaicEngine(
            device: device,
            settings: options.settings,
            source: pool,
            planner: planning.planner,
            library: library,
            seed: options.seed,
            tilePixelWidth: options.tileWidth
        )
    }
}
