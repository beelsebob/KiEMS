import simd

// Shared GPU-layout value types and camera math for every real (non-flat) 3D Metal view in this
// app -- currently FieldView (orbit + perspective) and GeometryView (orbit + orthographic). Kept
// in one place so the two views' cameras stay byte-for-byte/behaviorally identical wherever they
// overlap, rather than two hand-copied implementations drifting apart.

/// A plain 3-`Float` struct, not `SIMD3<Float>` -- Swift pads `SIMD3<Float>` to 16 bytes (the same
/// stride as `SIMD4<Float>`) for alignment, while Metal's `packed_float3` is a tightly-packed 12
/// bytes with no padding. A struct of three independent `Float` fields (no SIMD/vector type
/// anywhere in it) has no such alignment inflation and matches `packed_float3` exactly -- see
/// FieldShaders.metal's own buffers, every one of which uses `packed_float3`, never `float3`, for
/// this reason.
struct Position3 {
    var x: Float
    var y: Float
    var z: Float
    init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Matches FieldShaders.metal's own `FieldUniforms` -- `simd_float4x4` has no packed-vs-SIMD
/// layout ambiguity the way float3 does (Metal's own `float4x4` is column-major, 4x16-byte columns,
/// exactly matching `simd_float4x4`'s own layout), so this one's safe to use directly.
struct FieldUniformsGPU {
    var viewProjection: simd_float4x4
    var time: Float = 0
}

/// Per-frame inputs for GeometryView's physically based board-material shader. SIMD4 fields keep
/// the Swift/Metal layout unambiguous while carrying world-space xyz values.
struct GeometryPBRUniformsGPU {
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var lightDirection: SIMD4<Float>
    /// Maps a fragment's world XY into the padded, board-space distance texture. Keeping this
    /// independent of the visible camera means simulated copper remains a seed while off screen.
    var regionWorldMin: SIMD2<Float> = .zero
    var regionWorldInverseSize: SIMD2<Float> = .zero
    /// Hull padding expressed in distance-texture pixels. Negative disables the region test.
    var hullPaddingPixels: Float = -1
}

/// Projects board-space seed geometry into the padded distance-field texture.
struct RegionSeedUniformsGPU {
    var worldMin: SIMD2<Float>
    var worldInverseSize: SIMD2<Float>
}

/// Right-handed view matrix: camera at `eye` looking toward `center`, `up` fixed as the reference
/// vertical (both FieldView and GeometryView use `SIMD3(0, 0, 1)` -- the board lies flat in the XY
/// plane, Z is its own thin thickness axis). View space has -Z as "forward," matching Metal's own
/// convention -- see perspective(...)/orthographic(...)'s own derivations, which both depend on it.
func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(SIMD4(s.x, u.x, -f.x, 0),
                          SIMD4(s.y, u.y, -f.y, 0),
                          SIMD4(s.z, u.z, -f.z, 0),
                          SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1))
}

/// Standard Metal (depth range [0, 1], not OpenGL's [-1, 1]) perspective projection.
func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovYRadians * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(SIMD4(x, 0, 0, 0),
                          SIMD4(0, y, 0, 0),
                          SIMD4(0, 0, z, -1),
                          SIMD4(0, 0, z * near, 0))
}

/// Standard Metal (depth range [0, 1]) orthographic (parallel) projection: maps a `width` x
/// `height` x `[near, far]` view-space box, centered on the view axis, directly to clip space with
/// no perspective divide (clip.w is always 1) -- the defining property of an isometric-style
/// camera: apparent size doesn't change with distance, and an axis-aligned view looks perfectly
/// flat/2D, with none of perspective's own foreshortening.
func orthographic(width: Float, height: Float, near: Float, far: Float) -> simd_float4x4 {
    simd_float4x4(SIMD4(2 / width, 0, 0, 0),
                  SIMD4(0, 2 / height, 0, 0),
                  SIMD4(0, 0, 1 / (near - far), 0),
                  SIMD4(0, 0, near / (near - far), 1))
}
