#include <metal_stdlib>
using namespace metal;

struct DepthMeshVertex {
    packed_float3 position;  // +Y Up right-handed world space (meters)
    packed_float2 uv;        // Normalized equirectangular UV in [0, 1] x [0, 1]
};

struct ReprojectionUniforms {
    float3 rRow0;      // +X_cam (cameraRight)
    float tx;          // t_cw.x
    float3 rRow1;      // +Y_cam (cameraDown)
    float ty;          // t_cw.y
    float3 rRow2;      // +Z_cam (cameraForward)
    float tz;          // t_cw.z
    float focalLength; // SIMPLE_PINHOLE f (pixels)
    float cx;          // principal point X (pixels)
    float cy;          // principal point Y (pixels)
    float width;       // render target width (pixels)
    float height;      // render target height (pixels)
    float zNear;       // near clip plane (meters)
    float zFar;        // far clip plane (meters)
    float _pad0;
};

struct ReprojectionVertexOut {
    float4 clipPosition [[position]];
    float2 uv;
};

struct ReprojectionFragmentOut {
    float4 color [[color(0)]];
    float mask   [[color(1)]];
};

vertex ReprojectionVertexOut parallaxReprojectVertex(
    uint vertexID [[vertex_id]],
    const device DepthMeshVertex *vertices [[buffer(0)]],
    constant ReprojectionUniforms &u [[buffer(1)]]
) {
    ReprojectionVertexOut out;
    float3 pWorld = float3(vertices[vertexID].position);

    // Transform world point into COLMAP camera space (+X right, +Y down, +Z forward)
    float xc = dot(u.rRow0, pWorld) + u.tx;
    float yc = dot(u.rRow1, pWorld) + u.ty;
    float zc = dot(u.rRow2, pWorld) + u.tz;

    // Exact COLMAP SIMPLE_PINHOLE projection into Metal clip space:
    //   px = f * (xc / zc) + cx  =>  x_ndc = (2 * px / W) - 1
    //   py = f * (yc / zc) + cy  =>  y_ndc = 1 - (2 * py / H)  (Metal +Y NDC is top of image)
    float xClip = ((2.0f * u.focalLength) / u.width) * xc + ((2.0f * u.cx) / u.width - 1.0f) * zc;
    float yClip = ((-2.0f * u.focalLength) / u.height) * yc + (1.0f - (2.0f * u.cy) / u.height) * zc;

    // Metal depth range [0, 1] for zc in [zNear, zFar]
    float a = u.zFar / (u.zFar - u.zNear);
    float b = -(u.zFar * u.zNear) / (u.zFar - u.zNear);
    float zClip = a * zc + b;

    out.clipPosition = float4(xClip, yClip, zClip, zc);
    out.uv = float2(vertices[vertexID].uv);
    return out;
}

fragment ReprojectionFragmentOut parallaxReprojectFragment(
    ReprojectionVertexOut in [[stage_in]],
    texture2d<float, access::sample> equirectTexture [[texture(0)]]
) {
    constexpr sampler bilinearSampler(
        coord::normalized,
        s_address::repeat,
        t_address::clamp_to_edge,
        filter::linear
    );

    float4 sampled = equirectTexture.sample(bilinearSampler, in.uv);
    sampled.a = 1.0f;

    ReprojectionFragmentOut out;
    out.color = sampled;
    out.mask = 1.0f; // White (255) = valid projected pixel; cleared pixels remain 0.0 (black disoccluded hole)
    return out;
}

struct MaskErodeParams {
    uint width;
    uint height;
    int radius;
    uint _pad0;
};

/// Erodes the disocclusion mask by `radius` pixels so boundary fringes around depth tears are cleanly ignored by Brush.
kernel void erodeDisocclusionMask(
    texture2d<float, access::read> inputMask [[texture(0)]],
    texture2d<float, access::write> outputMask [[texture(1)]],
    constant MaskErodeParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float minVal = 1.0f;
    int r = params.radius;
    int maxX = int(params.width) - 1;
    int maxY = int(params.height) - 1;

    for (int dy = -r; dy <= r; ++dy) {
        int sy = clamp(int(gid.y) + dy, 0, maxY);
        for (int dx = -r; dx <= r; ++dx) {
            int sx = clamp(int(gid.x) + dx, 0, maxX);
            float val = inputMask.read(uint2(uint(sx), uint(sy))).r;
            minVal = min(minVal, val);
        }
    }

    outputMask.write(float4(minVal, minVal, minVal, 1.0f), gid);
}
