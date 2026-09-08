#include <metal_stdlib>
using namespace metal;

// Sample once at a displaced point. The inner face is unchanged; only the
// curved rim bends the label. There is no blur kernel or second text layer.
[[ stitchable ]] float2 listLens(float2 position, float4 bounds) {
    float2 center = bounds.xy + bounds.zw * 0.5;
    float radius = bounds.w * 0.5;
    float halfStraight = max(0.0, bounds.z * 0.5 - radius);
    float2 local = position - center;
    float2 spine = float2(clamp(local.x, -halfStraight, halfStraight), 0.0);
    float2 radial = local - spine;
    float distance = length(radial);
    if (radius <= 0.0 || distance >= radius || distance <= radius * 0.6) {
        return position;
    }
    float rim = smoothstep(radius * 0.6, radius, distance);
    float displacement = min(8.0, radius * 0.32) * rim * rim;
    return position - radial / distance * displacement;
}
