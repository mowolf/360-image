#include <metal_stdlib>
using namespace metal;

struct PanoVertexOut {
    float4 position [[position]];
    float2 ndc;
};

// Single full-screen triangle.
vertex PanoVertexOut pano_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PanoVertexOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.ndc = p * 2.0 - 1.0;
    return o;
}

struct PanoUniforms {
    float yaw;          // radians, + = look right
    float pitch;        // radians, + = look up
    float tanHalfFovY;
    float aspect;       // width / height
};

// Rectilinear view into an equirectangular panorama: every screen pixel is turned into
// a ray, rotated by pitch then yaw, and looked up in the equirectangular texture.
fragment float4 pano_fragment(PanoVertexOut in [[stage_in]],
                              constant PanoUniforms &u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::repeat);
    float3 d = normalize(float3(in.ndc.x * u.tanHalfFovY * u.aspect, in.ndc.y * u.tanHalfFovY, -1.0));
    float cp = cos(u.pitch), sp = sin(u.pitch);
    d = float3(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
    float cy = cos(u.yaw), sy = sin(u.yaw);
    d = float3(d.x * cy - d.z * sy, d.y, d.x * sy + d.z * cy);
    float lon = atan2(d.x, -d.z);
    float lat = asin(clamp(d.y, -1.0, 1.0));
    float2 tc = float2(lon / (2.0 * M_PI_F) + 0.5, 0.5 - lat / M_PI_F);
    return float4(tex.sample(s, tc, level(0)).rgb, 1.0);
}
