// swift-tools-version: 6.2

import PackageDescription

// The module boundaries drawn in PLAN.md are expressed here as target
// dependencies, so the compiler refuses any arrow that points back up the
// diagram. PLAN.md originally called for four separate packages; one manifest
// enforces exactly the same boundaries for a single-author repository, and the
// decision is recorded there.
//
// Modules are created when they are needed, not in advance.
let package = Package(
    name: "Mosaic",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MosaicEngine", targets: ["MosaicEngine"]),
        // The .saver's executable. Dynamic, so that SwiftPM links it with the
        // Swift driver: a bundle linked by clang loads but crashes on its first
        // Swift global (spike 1). Hosts/Saver/build.sh wraps it in a bundle.
        .library(name: "MosaicSaver", type: .dynamic, targets: ["MosaicSaver"]),
    ],
    targets: [
        // M1 — domain types and grid maths. Depends on nothing but Foundation.
        .target(name: "MosaicCore"),

        // M2 — the zoom curve and the cycle state machine. Pure: given a time,
        // it returns a FrameState. No I/O, no GPU, no AppKit.
        .target(name: "CycleEngine", dependencies: ["MosaicCore"]),

        // M3 — the photomosaic itself. Pure: colours in, a layout out. No I/O,
        // no CoreGraphics, no knowledge of where the colours were measured.
        .target(name: "MosaicSolver", dependencies: ["MosaicCore"]),

        // M4 — where images come from: synthetic, and a folder on disk.
        .target(name: "MosaicPhotos", dependencies: ["MosaicCore"]),

        // M4 — the Photos library. A target of its own so that nothing the
        // saver links can reach PhotoKit: only the app depends on it.
        .target(name: "MosaicPhotoKit", dependencies: ["MosaicCore", "MosaicPhotos"]),

        // M5 — the persistent index: the "Creating photo database" of the
        // original, made incremental. Depends on MosaicPhotos because it reads
        // through a PhotoSource, and on nothing above it.
        .target(name: "PhotoIndex", dependencies: ["MosaicCore", "MosaicPhotos"]),

        // M7 — Metal. Shaders.metal is excluded from the Swift build: it is
        // compiled to default.metallib by the host build scripts, because
        // `swift build` has no rule for Metal sources.
        // CycleEngine is a dependency because FrameState lives there, and
        // FrameState is the renderer's entire input. That arrow does not go back
        // up the diagram: M2 is foundations, below rendering.
        .target(
            name: "MosaicRender",
            dependencies: ["MosaicCore", "CycleEngine"],
            exclude: ["Shaders.metal"]
        ),

        // M6 — the textures behind the renderer: the atlas of every tile and the
        // close-ups of the few that grow bigger than a slice. GPU and volatile,
        // where M5 is CPU, disk and persistent. It implements the contract M7
        // consumes, which is why it sits beside the renderer and not below it.
        .target(
            name: "TileStore",
            dependencies: ["MosaicCore", "MosaicPhotos", "MosaicRender"]
        ),

        // M8 — the only class a host instantiates, and the public boundary of
        // the whole library. It exists from the first day even though PLAN.md
        // schedules it for milestone 3: if the harness did the orchestrating,
        // that orchestration would be code the saver cannot reuse.
        .target(
            name: "MosaicEngine",
            dependencies: [
                "MosaicCore", "CycleEngine", "MosaicPhotos", "MosaicRender",
                "MosaicSolver", "PhotoIndex", "TileStore",
            ]
        ),

        // M11 — the paths the app and the .saver agree on (spike 2). Foundation
        // only: the saver links it.
        .target(name: "SharedStore"),

        // The app's own updates: which release is newer, read from GitHub.
        // Foundation only and pure; downloading and installing are the app's.
        .target(name: "AppUpdate"),

        // M9 — the development harness. A thin shell over MosaicEngine.
        .executableTarget(
            name: "MosaicApp",
            // The host picks the settings (M1) and where the photographs come
            // from (M4), and drives the engine (M8). It has no business knowing
            // that there is a renderer behind it.
            dependencies: [
                "MosaicEngine", "MosaicCore", "MosaicPhotos", "MosaicPhotoKit", "PhotoIndex", "SharedStore",
                "AppUpdate",
            ],
            path: "Hosts/App",
            // build.sh and the Help Book live next to the sources; build.sh
            // copies the Help Book into the bundle, so SwiftPM only needs
            // telling that neither is one of them.
            exclude: ["build.sh", "Help"]
        ),

        // M10 — the screen saver: a thin shell over MosaicEngine that reads the
        // index and nothing else. No MosaicPhotoKit, ever.
        .target(
            name: "MosaicSaver",
            dependencies: ["MosaicEngine", "MosaicCore", "PhotoIndex", "SharedStore"],
            path: "Hosts/Saver",
            exclude: ["build.sh"]
        ),

        .testTarget(name: "MosaicCoreTests", dependencies: ["MosaicCore"]),
        .testTarget(name: "MosaicSolverTests", dependencies: ["MosaicSolver", "MosaicCore"]),
        .testTarget(name: "MosaicPhotosTests", dependencies: ["MosaicPhotos", "MosaicCore"]),
        .testTarget(name: "MosaicPhotoKitTests", dependencies: ["MosaicPhotoKit", "MosaicPhotos", "MosaicCore"]),
        .testTarget(name: "PhotoIndexTests", dependencies: ["PhotoIndex", "MosaicPhotos", "MosaicCore"]),
        .testTarget(name: "MosaicEngineTests", dependencies: ["MosaicEngine", "MosaicSolver", "MosaicCore", "PhotoIndex"]),
        .testTarget(name: "CycleEngineTests", dependencies: ["CycleEngine", "MosaicCore"]),
        .testTarget(name: "SharedStoreTests", dependencies: ["SharedStore"]),
        .testTarget(name: "AppUpdateTests", dependencies: ["AppUpdate"]),
    ]
)
