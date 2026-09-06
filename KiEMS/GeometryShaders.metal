// Vertex/fragment pair for GeometryView's whole scene -- opaque colored triangles (copper fills,
// via rings/holes, port dots, all pre-ordered back-to-front on the CPU side, painter's-algorithm
// style, no depth buffer) and the board outline (as a line strip). Position/color are supplied as
// two flat, parallel buffers rather than one interleaved vertex struct, so there's no risk of the
// Swift-side struct layout silently drifting from this one.
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// Maps board-space (simulation units, Y-down to match KiCad) straight to clip space: precomputed
// on the CPU once per frame from the current pan/zoom state, not touched here.
struct Uniforms {
    float2 scale;
    float2 offset;
};

vertex VertexOut geometry_vertex(uint vertexID [[vertex_id]],
                                  constant packed_float2* positions [[buffer(0)]],
                                  constant packed_float4* colors [[buffer(1)]],
                                  constant Uniforms& uniforms [[buffer(2)]]) {
    VertexOut out;
    float2 position = positions[vertexID] * uniforms.scale + uniforms.offset;
    out.position = float4(position, 0.0, 1.0);
    out.color = colors[vertexID];
    return out;
}

fragment float4 geometry_fragment(VertexOut in [[stage_in]]) {
    return in.color;
}
