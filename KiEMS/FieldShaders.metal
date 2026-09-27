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
    // Seconds since the owning view first started animating -- unused by every draw pass except
    // board_activity_fragment below; harmless (just an unread trailing field) for every other use
    // of this same struct.
    float time;
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

// Selection uses the same depth-tested overlay path, but is nudged a very small, constant amount
// toward the camera in normalized depth. This avoids coplanar z-fighting with the selected copper
// without disabling depth testing (so genuinely nearer STEP geometry still occludes it). Applying
// the offset in clip space keeps it independent of board scale and camera distance.
vertex OverlayVertexOut geometry_highlight_vertex(uint vertexID [[vertex_id]],
                                                    constant packed_float3* positions [[buffer(0)]],
                                                    constant packed_float4* colors [[buffer(1)]],
                                                    constant FieldUniforms& uniforms [[buffer(2)]]) {
    OverlayVertexOut out;
    out.position = uniforms.viewProjection * float4(positions[vertexID], 1.0);
    out.position.z -= 0.00002 * out.position.w;
    out.color = colors[vertexID];
    return out;
}

// MARK: - Board activity (simulation-included-net flashing / excitation ripple overlay)
//
// A second, independent translucent overlay -- distinct from the click-selection highlight above
// (same nudge-toward-camera trick, so neither z-fights the opaque copper both draw on top of) --
// marking which of the whole board's nets actually take part in the currently selected simulation.
// An included net with no real excitation reaching it (directly, or through a chain of passive
// components -- see WholeBoardViewController.BoardActivityHighlight/GeometryView's own
// rebuildActivityBuffers()) just flashes gently in place; one that *is* excitation-reachable
// instead shows a traveling brightness wave radiating outward from the excitation point, using
// each vertex's own precomputed distance-along-that-path (rippleDistance) as the wave's phase.
struct ActivityVertexOut {
    float4 position [[position]];
    float4 color;
    float rippleDistance;
};

vertex ActivityVertexOut board_activity_vertex(uint vertexID [[vertex_id]],
                                                 constant packed_float3* positions [[buffer(0)]],
                                                 constant packed_float4* colors [[buffer(1)]],
                                                 constant FieldUniforms& uniforms [[buffer(2)]],
                                                 constant float* rippleDistances [[buffer(3)]]) {
    ActivityVertexOut out;
    out.position = uniforms.viewProjection * float4(positions[vertexID], 1.0);
    out.position.z -= 0.00001 * out.position.w;
    out.color = colors[vertexID];
    out.rippleDistance = rippleDistances[vertexID];
    return out;
}

fragment float4 board_activity_fragment(ActivityVertexOut in [[stage_in]],
                                         constant FieldUniforms& uniforms [[buffer(2)]]) {
    // rippleDistance < 0 is the "no excitation path reaches this vertex" sentinel (see
    // GeometryView.rebuildActivityBuffers()) -- everything else on an included net still gets the
    // plain, uniform flash.
    float alpha;
    if (in.rippleDistance >= 0.0) {
        // Wavelength/speed tuned for a readable pulse at typical board scale (sim units -- 10000
        // per mm) and playback speed -- a ~2mm-wide pulse traveling at ~4mm/s.
        const float wavelength = 20000.0;
        const float speed = 40000.0;
        float phase = (in.rippleDistance - uniforms.time * speed) / wavelength * 6.28318530718;
        float wave = max(0.0, sin(phase));
        alpha = wave * wave * 0.85;
    } else {
        alpha = 0.12 + 0.10 * (0.5 + 0.5 * sin(uniforms.time * 3.0));
    }
    return float4(in.color.rgb, in.color.a * alpha);
}

// MARK: - Geometry preview PBR materials

struct GeometryPBRUniforms {
    float4x4 viewProjection;
    float4 cameraPosition;
    float4 lightDirection;
    float2 regionWorldMin;
    float2 regionWorldInverseSize;
    float hullPaddingPixels;
};

struct GeometryPBRVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float4 baseColor;
    // Tri-state region/muting disposition; see GeometryView.boardMuteFlagBuffer's documentation.
    // Keeping it separate from baseColor lets the fragment combine it once with the region test.
    float muteFlag [[flat]];
};

vertex GeometryPBRVertexOut geometry_pbr_vertex(uint vertexID [[vertex_id]],
                                                 constant packed_float3* positions [[buffer(0)]],
                                                 constant packed_float4* colors [[buffer(1)]],
                                                 constant packed_float3* normals [[buffer(2)]],
                                                 constant GeometryPBRUniforms& uniforms [[buffer(3)]],
                                                 constant float* muteFlags [[buffer(4)]]) {
    GeometryPBRVertexOut out;
    const float3 worldPosition = positions[vertexID];
    out.position = uniforms.viewProjection * float4(worldPosition, 1.0);
    out.worldPosition = worldPosition;
    out.normal = normals[vertexID];
    out.baseColor = colors[vertexID];
    out.muteFlag = muteFlags[vertexID];
    return out;
}

fragment float4 geometry_pbr_fragment(GeometryPBRVertexOut in [[stage_in]],
                                       constant GeometryPBRUniforms& uniforms [[buffer(3)]],
                                       texture2d<half, access::sample> regionDistance [[texture(0)]]) {
    const float pi = 3.14159265359;

    // Exact board-space simulation-region highlight: a negative threshold disables it. Combined
    // with the legacy per-vertex
    // muteFlag via OR (not compounded -- see GeometryPBRVertexOut.muteFlag's own doc comment) before
    // applying the same "40% saturation/value" dim either reason uses.
    const bool forceInsideRegion = in.muteFlag < -0.5;
    bool dimmed = in.muteFlag > 0.5;
    if (uniforms.hullPaddingPixels >= 0.0 && !forceInsideRegion) {
        constexpr sampler regionSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (in.worldPosition.xy - uniforms.regionWorldMin) * uniforms.regionWorldInverseSize;
        if (any(uv < 0.0) || any(uv > 1.0)) {
            dimmed = true;
        } else {
            float regionDistanceValue = float(regionDistance.sample(regionSampler, uv).r);
            dimmed = dimmed || regionDistanceValue > uniforms.hullPaddingPixels;
        }
    }
    float4 baseColor = in.baseColor;
    if (dimmed) {
        float maximum = max(baseColor.r, max(baseColor.g, baseColor.b));
        baseColor.rgb = (maximum - (maximum - baseColor.rgb) * 0.4) * 0.4;
    }

    float3 V = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    float3 N = normalize(in.normal);
    if (dot(N, V) < 0.0) N = -N; // Board sheets and STEP meshes are intentionally double-sided.
    const float3 L = normalize(-uniforms.lightDirection.xyz);
    const float3 H = normalize(V + L);
    const float NdotL = saturate(dot(N, L));
    const float NdotV = max(dot(N, V), 0.001);
    const float NdotH = saturate(dot(N, H));
    const float VdotH = saturate(dot(V, H));

    // Muted geometry should recede as a material as well as in colour: suppress its metallic
    // reflection and broaden the remaining highlight into a much softer, rougher response.
    const float metallic = dimmed ? 0.05 : 0.256;
    const float roughness = dimmed ? 0.78 : 0.50;
    const float alpha = roughness * roughness;
    const float alpha2 = alpha * alpha;
    const float denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
    const float D = alpha2 / max(pi * denom * denom, 0.0001);
    const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    const float Gv = NdotV / (NdotV * (1.0 - k) + k);
    const float Gl = NdotL / (NdotL * (1.0 - k) + k);
    const float3 F0 = mix(float3(0.04), baseColor.rgb, metallic);
    const float3 F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
    const float3 specular = D * Gv * Gl * F / max(4.0 * NdotV * NdotL, 0.001);
    const float3 diffuse = (1.0 - F) * (1.0 - metallic) * baseColor.rgb / pi;
    const float3 direct = (diffuse + specular) * NdotL * 2.4;
    const float3 ambient = baseColor.rgb * 0.28;
    return float4(ambient + direct, baseColor.a);
}

// MARK: - Simulation region highlight (exact board-space Euclidean distance transform).

struct RegionSeedVertexOut {
    float4 position [[position]];
};

struct RegionSeedUniforms {
    float2 worldMin;
    float2 worldInverseSize;
};

// The distance texture is wider than the board by the hull-padding radius on every side. Project
// directly from world XY into that padded top-down field rather than through the visible camera.
vertex RegionSeedVertexOut board_region_seed_vertex(uint vertexID [[vertex_id]],
                                                      constant packed_float3* positions [[buffer(0)]],
                                                      constant RegionSeedUniforms& uniforms [[buffer(2)]]) {
    RegionSeedVertexOut out;
    float2 uv = (positions[vertexID].xy - uniforms.worldMin) * uniforms.worldInverseSize;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return out;
}

fragment half board_region_seed_fragment() {
    return 1.0h;
}

// MARK: - Geometry picking

// A deliberately unlit off-screen pass. Each triangle carries one integer object identifier into
// an R32Uint target, avoiding color-space conversion, blending, and 24-bit RGB packing. Identifier
// zero is the cleared background/unselectable value.
struct GeometryPickVertexOut {
    float4 position [[position]];
    uint identifier [[flat]];
};

vertex GeometryPickVertexOut geometry_pick_vertex(uint vertexID [[vertex_id]],
                                                    constant packed_float3* positions [[buffer(0)]],
                                                    constant uint* identifiers [[buffer(1)]],
                                                    constant FieldUniforms& uniforms [[buffer(2)]]) {
    GeometryPickVertexOut out;
    out.position = uniforms.viewProjection * float4(positions[vertexID], 1.0);
    out.identifier = identifiers[vertexID];
    return out;
}

fragment uint geometry_pick_fragment(GeometryPickVertexOut in [[stage_in]]) {
    return in.identifier;
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
