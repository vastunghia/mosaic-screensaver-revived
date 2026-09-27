// Shaders for the mosaic.
//
// `swift build` has no rule for Metal sources, so this file is excluded from the
// Swift target and compiled to default.metallib by the host build scripts. The
// Swift-side mirror of these structs is in ShaderTypes.swift; the two layouts
// have to be changed together.

#include <metal_stdlib>
using namespace metal;

struct TileInstance {
    float2 origin;   // top-left corner, in mosaic space
    float2 size;
    float  slice;    // index into the tile texture array
    float  alpha;
    float2 padding;
};

struct CameraUniforms {
    float2 center;   // in mosaic space
    float  halfSpan; // half the visible width, in mosaic space
    float  padding;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float  slice [[flat]];
    float  alpha [[flat]];
};

// The quad is generated from the vertex id: four vertices, one triangle strip,
// no vertex buffer. Everything else is per-instance.
vertex VertexOut tile_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device TileInstance *instances [[buffer(0)]],
                             constant CameraUniforms &camera [[buffer(1)]])
{
    const float2 corner = float2((vid == 1 || vid == 3) ? 1.0 : 0.0,
                                 (vid >= 2) ? 1.0 : 0.0);

    const device TileInstance &tile = instances[iid];
    const float2 p = tile.origin + corner * tile.size;

    // Mosaic space is square and a screenful wide, so the projection carries no
    // aspect ratio: it is a translation and a scale. The y axis is flipped
    // because mosaic space grows downwards and clip space grows upwards.
    const float2 ndc = (p - camera.center) / camera.halfSpan;

    VertexOut out;
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    out.uv = corner;
    out.slice = tile.slice;
    out.alpha = tile.alpha;
    return out;
}

fragment float4 tile_fragment(VertexOut in [[stage_in]],
                              texture2d_array<float> tiles [[texture(0)]],
                              sampler tileSampler [[sampler(0)]])
{
    // No colour correction of any kind: SPEC § 2 wants the photographs' own
    // colours. The mip level is chosen by the sampler from the screen-space
    // derivatives of uv, which is what keeps a full mosaic of R² tiles costing
    // about one screenful of texels (SPEC § 6).
    const float4 colour = tiles.sample(tileSampler, in.uv, uint(in.slice));
    return float4(colour.rgb * in.alpha, in.alpha);
}

// A close-up: one photograph in a texture of its own, at the size it reaches on
// screen, instead of its slice of the atlas. Same quad, same alpha, same absence
// of any colour correction.
fragment float4 close_up_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> photo [[texture(0)]],
                                  sampler tileSampler [[sampler(0)]])
{
    const float4 colour = photo.sample(tileSampler, in.uv);
    return float4(colour.rgb * in.alpha, in.alpha);
}
