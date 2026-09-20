import simd

// Swift mirrors of the structs in Shaders.metal. The layouts have to match, and
// there is no shared header to enforce it: a bridging header would have to be
// reachable from both the Metal compile in build.sh and the Swift target, which
// SwiftPM makes awkward. The tests assert the sizes instead.

struct TileInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var slice: Float
    var alpha: Float
    var padding: SIMD2<Float> = .zero
}

struct CameraUniforms {
    var center: SIMD2<Float>
    var halfSpan: Float
    var padding: Float = 0
}
