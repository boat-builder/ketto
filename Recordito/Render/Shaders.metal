#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut compositeVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    return out;
}

fragment float4 compositeFragment(VertexOut in [[stage_in]], constant FrameUniforms &u [[buffer(0)]]) {
    return float4(in.position.xy / u.targetSize, 0, 1);
}
