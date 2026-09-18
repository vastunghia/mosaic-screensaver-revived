#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

struct Uniforms {
    float angle;
    float aspect;
};

vertex VertexOut spike_vertex(uint vid [[vertex_id]],
                              constant Uniforms &u [[buffer(0)]])
{
    const float2 corners[3] = { float2(0.0, 0.62), float2(-0.54, -0.31), float2(0.54, -0.31) };
    const float4 colors[3]  = { float4(0.96, 0.35, 0.22, 1.0),
                                float4(0.30, 0.86, 0.45, 1.0),
                                float4(0.32, 0.48, 0.98, 1.0) };

    float2 p = corners[vid];
    float s = sin(u.angle);
    float c = cos(u.angle);
    float2 r = float2(p.x * c - p.y * s, p.x * s + p.y * c);
    r.x /= u.aspect;

    VertexOut out;
    out.position = float4(r, 0.0, 1.0);
    out.color = colors[vid];
    return out;
}

fragment float4 spike_fragment(VertexOut in [[stage_in]])
{
    return in.color;
}
