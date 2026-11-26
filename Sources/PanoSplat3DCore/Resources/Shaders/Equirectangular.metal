#include <metal_stdlib>
using namespace metal;

struct PerspectiveSliceParams {
    float3 cameraRight;    // +X_cam in COLMAP RDF world space (+X right, +Y down, +Z forward)
    float focalLength;     // focal length in pixels (SIMPLE_PINHOLE f)
    float3 cameraDown;     // +Y_cam in COLMAP RDF world space
    float cx;              // principal point X in pixels
    float3 cameraForward;  // +Z_cam in COLMAP RDF world space
    float cy;              // principal point Y in pixels
    uint outputWidth;
    uint outputHeight;
    uint _pad0;
    uint _pad1;
};

kernel void sliceEquirectangularToPerspective(
    texture2d<float, access::sample> equirectTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant PerspectiveSliceParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputWidth || gid.y >= params.outputHeight) {
        return;
    }

    // Pixel center coordinates in COLMAP image convention (origin top-left, +X right, +Y down)
    float px = float(gid.x) + 0.5f;
    float py = float(gid.y) + 0.5f;

    float rx = (px - params.cx) / params.focalLength;
    float ry = (py - params.cy) / params.focalLength;

    // Transform camera-space ray (rx, ry, 1) into COLMAP RDF world space
    float3 worldDir = normalize(
        rx * params.cameraRight +
        ry * params.cameraDown +
        params.cameraForward
    );

    // Map unit COLMAP RDF world ray (+X right, +Y down, +Z forward) to equirectangular UV
    constexpr float twoPi = 6.28318530717958647692f;
    constexpr float pi = 3.14159265358979323846f;

    float phi = atan2(worldDir.x, worldDir.z);             // [-pi, +pi], 0 at +Z forward
    float theta = asin(clamp(-worldDir.y, -1.0f, 1.0f));   // [-pi/2, +pi/2], +pi/2 at -Y zenith

    float u = fract(0.5f + phi / twoPi);
    float v = clamp(0.5f - theta / pi, 0.0f, 1.0f);

    constexpr sampler bilinearSampler(
        coord::normalized,
        s_address::repeat,
        t_address::clamp_to_edge,
        filter::linear
    );

    float4 color = equirectTexture.sample(bilinearSampler, float2(u, v));
    color.a = 1.0f;
    outputTexture.write(color, gid);
}
