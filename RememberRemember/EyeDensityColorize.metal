#include <metal_stdlib>
using namespace metal;

/// Maps one grayscale density byte per pixel through the EnergyColorMap ramp (supplied as a
/// linearly-filtered 1D texture so the Swift side remains the single definition of the colours),
/// writing premultiplied RGBA8 -- the same output EyeDiagramView's CPU loop used to produce.
kernel void colorizeEyeDensity(device const uchar *density [[buffer(0)]],
                               device uchar4 *output [[buffer(1)]],
                               constant float &densityScale [[buffer(2)]],
                               constant uint &pixelCount [[buffer(3)]],
                               texture1d<float> ramp [[texture(0)]],
                               uint index [[thread_position_in_grid]]) {
    if (index >= pixelCount) return;
    constexpr sampler rampSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    const float value = saturate(float(density[index]) * densityScale);
    // Sample at texel centres so 0 and 1 hit the ramp's end stops exactly.
    const float width = float(ramp.get_width());
    const float3 rgb = ramp.sample(rampSampler, (value * (width - 1) + 0.5) / width).rgb;
    // Eye-density opacity: see EnergyColorMap.rgba(at:).
    const float alpha = saturate(value / 0.25);
    output[index] = uchar4(round(float4(rgb * alpha, alpha) * 255.0));
}
