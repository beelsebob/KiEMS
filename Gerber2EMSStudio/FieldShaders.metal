// Vertex/fragment pairs for FieldView's 3D scene: a real camera (unlike GeometryShaders.metal's
// flat board->pixel affine transform), one combined view-projection matrix computed on the CPU
// once per frame from the current orbit state. Two independent draw passes share it:
//   - field_overlay_*: the Geometry tab's own board fills/vias/outline, laid out flat at the
//     board's own top Z, uniformly translucent (alpha baked into each vertex color CPU-side).
//   - field_voxel_*: one instanced unit cube per FDTD cell, non-uniformly scaled/positioned per
//     instance to match that cell's own (possibly very non-uniform) real mesh dimensions, colored
//     per-instance from the energy gradient (also resolved CPU-side, not looked up in the shader).
#include <metal_stdlib>
using namespace metal;

struct FieldUniforms {
    float4x4 viewProjection;
};

// MARK: - Overlay (translucent board geometry reference plane)

struct OverlayVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex OverlayVertexOut field_overlay_vertex(uint vertexID [[vertex_id]],
                                              constant packed_float3* positions [[buffer(0)]],
                                              constant packed_float4* colors [[buffer(1)]],
                                              constant FieldUniforms& uniforms [[buffer(2)]]) {
    OverlayVertexOut out;
    out.position = uniforms.viewProjection * float4(positions[vertexID], 1.0);
    out.color = colors[vertexID];
    return out;
}

fragment float4 field_overlay_fragment(OverlayVertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Voxels (instanced, per-cell-sized cubes)

// One FDTD cell's shape -- `center`/`size` are world-space (simulation units), `size` the cell's
// own full (non-uniform) extent per axis, not a half-extent (see field_voxel_vertex's own scaling
// below). Split from its color into a separate buffer/struct (VoxelInstance used to carry both)
// since the mesh geometry is fixed for a whole snapshot while the color changes every playback
// frame -- keeping them apart lets a frame change rebuild only the (much cheaper) color buffer,
// not re-walk the full nx*ny*nz cell grid to recompute positions/sizes that haven't moved.
struct VoxelGeometry {
    packed_float3 center;
    packed_float3 size;
};

struct VoxelVertexOut {
    float4 position [[position]];
    float4 color;
};

// `cubeVertices` is a fixed, shared 36-vertex unit cube (corners at +/-0.5 on each axis, see
// FieldView.swift's own unitCubeVertices) -- every instance reuses the identical base mesh, only
// `geometry[instanceID]`/`colors[instanceID]` differ per draw.
vertex VoxelVertexOut field_voxel_vertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                          constant packed_float3* cubeVertices [[buffer(0)]],
                                          constant VoxelGeometry* geometry [[buffer(1)]],
                                          constant packed_float4* colors [[buffer(2)]],
                                          constant FieldUniforms& uniforms [[buffer(3)]]) {
    VoxelVertexOut out;
    VoxelGeometry cell = geometry[instanceID];
    float3 worldPosition = cell.center + cubeVertices[vertexID] * cell.size;
    out.position = uniforms.viewProjection * float4(worldPosition, 1.0);
    out.color = colors[instanceID];
    return out;
}

fragment float4 field_voxel_fragment(VoxelVertexOut in [[stage_in]]) {
    return in.color;
}
