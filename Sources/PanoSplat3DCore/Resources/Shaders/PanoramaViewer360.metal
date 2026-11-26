#include <metal_stdlib>
using namespace metal;

struct Viewer360Uniforms {
    float yawRadians;
    float pitchRadians;
    float tanHalfFovY;
    float aspectRatio;
    uint showSeamGuide;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct Viewer360VertexOut {
    float4 position [[position]];
    float2 uv; // (0,0) top-left, (1,1) bottom-right
};

vertex Viewer360VertexOut panoramaViewer360Vertex(uint vertexID [[vertex_id]]) {
    // Full-screen triangle covering clip space [-1, 1] x [-1, 1]
    float2 clipPositions[3] = {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f)
    };
    float2 pos = clipPositions[vertexID];

    Viewer360VertexOut out;
    out.position = float4(pos, 0.0f, 1.0f);
    // Metal clip +Y is top of screen -> uv.y = 0 at top, 1 at bottom
    out.uv = float2(pos.x * 0.5f + 0.5f, 0.5f - pos.y * 0.5f);
    return out;
}

fragment float4 panoramaViewer360Fragment(
    Viewer360VertexOut in [[stage_in]],
    texture2d<float, access::sample> equirectTexture [[texture(0)]],
    constant Viewer360Uniforms &u [[buffer(0)]]
) {
    float rx = (in.uv.x * 2.0f - 1.0f) * u.aspectRatio * u.tanHalfFovY;
    float ry = (in.uv.y * 2.0f - 1.0f) * u.tanHalfFovY;

    float cosP = cos(u.pitchRadians);
    float sinP = sin(u.pitchRadians);
    float cosY = cos(u.yawRadians);
    float sinY = sin(u.yawRadians);

    // Camera basis in COLMAP RDF (+X right, +Y down, +Z forward)
    float3 forward = float3(cosP * sinY, -sinP, cosP * cosY);
    float3 right   = float3(cosY, 0.0f, -sinY);
    float3 down    = normalize(cross(forward, right));

    float3 worldDir = normalize(rx * right + ry * down + forward);

    constexpr float twoPi = 6.28318530717958647692f;
    constexpr float pi    = 3.14159265358979323846f;

    float phi   = atan2(worldDir.x, worldDir.z);           // [-pi, +pi], 0 at front, ±pi at back seam
    float theta = asin(clamp(-worldDir.y, -1.0f, 1.0f));   // [-pi/2, +pi/2], +pi/2 at zenith

    float sampleU = fract(0.5f + phi / twoPi);
    float sampleV = clamp(0.5f - theta / pi, 0.0f, 1.0f);

    constexpr sampler bilinearSampler(
        coord::normalized,
        s_address::repeat,
        t_address::clamp_to_edge,
        filter::linear
    );

    float4 color = equirectTexture.sample(bilinearSampler, float2(sampleU, sampleV));
    color.a = 1.0f;

    // Optional subtle seam & horizon inspection overlay (highlights the 0°/360° wrap meridian at phi = ±pi)
    if (u.showSeamGuide != 0u) {
        float seamDist = abs(pi - abs(phi));
        if (seamDist < 0.0045f) {
            float dash = step(0.45f, fract(sampleV * 36.0f));
            float blend = mix(0.15f, 0.78f, dash);
            color.rgb = mix(color.rgb, float3(1.0f, 0.65f, 0.15f), blend);
        }
        float horizonDist = abs(theta);
        if (horizonDist < 0.0025f) {
            color.rgb = mix(color.rgb, float3(0.35f, 0.85f, 1.0f), 0.35f);
        }
    }

    return color;
}
