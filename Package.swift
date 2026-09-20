// swift-tools-version: 6.2

import PackageDescription

// The module boundaries drawn in PLAN.md are expressed here as target
// dependencies, so the compiler refuses any arrow that points back up the
// diagram. PLAN.md originally called for four separate packages; one manifest
// enforces exactly the same boundaries for a single-author repository, and the
// decision is recorded there.
//
// Modules are created when they are needed, not in advance: MosaicSolver (M3),
// PhotoIndex (M5), TileStore (M6) and SharedStore (M11) do not exist yet.
let package = Package(
    name: "Mosaic",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MosaicEngine", targets: ["MosaicEngine"]),
    ],
    targets: [
        // M1 — domain types and grid maths. Depends on nothing but Foundation.
        .target(name: "MosaicCore"),

        // M2 — the zoom curve and the cycle state machine. Pure: given a time,
        // it returns a FrameState. No I/O, no GPU, no AppKit.
        .target(name: "CycleEngine", dependencies: ["MosaicCore"]),

        // M4 — where images come from. Only the synthetic source for now.
        .target(name: "MosaicPhotos", dependencies: ["MosaicCore"]),

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

        // M8 — the only class a host instantiates, and the public boundary of
        // the whole library. It exists from the first day even though PLAN.md
        // schedules it for milestone 3: if the harness did the orchestrating,
        // that orchestration would be code the saver cannot reuse.
        .target(
            name: "MosaicEngine",
            dependencies: ["MosaicCore", "CycleEngine", "MosaicPhotos", "MosaicRender"]
        ),

        // M9 — the development harness. A thin shell over MosaicEngine.
        .executableTarget(
            name: "MosaicApp",
            // The host picks the settings (M1) and where the photographs come
            // from (M4), and drives the engine (M8). It has no business knowing
            // that there is a renderer behind it.
            dependencies: ["MosaicEngine", "MosaicCore", "MosaicPhotos"],
            path: "Hosts/App"
        ),

        .testTarget(name: "MosaicCoreTests", dependencies: ["MosaicCore"]),
        .testTarget(name: "CycleEngineTests", dependencies: ["CycleEngine", "MosaicCore"]),
    ]
)
