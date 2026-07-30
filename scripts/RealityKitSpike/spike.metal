#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Forwards the material's custom float4 to the fragment stage.
[[visible]] void passGeometry(realitykit::geometry_parameters params)
{
    params.geometry().set_custom_attribute(params.uniforms().custom_parameter());
}

// Section clip: discard everything past the world-space plane (nx,ny,nz,d).
[[visible]] void clipSurface(realitykit::surface_parameters params)
{
    float4 plane = params.geometry().custom_attribute();
    float3 world = params.geometry().world_position();
    if (dot(world, plane.xyz) > plane.w) {
        discard_fragment();
    }
    params.surface().set_emissive_color(half3(0.1, 0.9, 0.2));
}

// Screen-space 45-degree hatch. custom = (viewW, viewH, spacingPx, lineWidthPx).
[[visible]] void hatchSurface(realitykit::surface_parameters params)
{
    float4 p = params.geometry().custom_attribute();
    float3 world = params.geometry().world_position();
    float4 view = params.uniforms().world_to_view() * float4(world, 1.0);
    float4 clip = params.uniforms().view_to_projection() * view;
    float2 ndc = clip.xy / clip.w;
    float2 pixel = (ndc * 0.5 + 0.5) * p.xy;
    float gap = max(p.z, 1.0);
    float phase = fract((pixel.x + pixel.y) / (gap * 1.41421356));
    float dist = min(phase, 1.0 - phase) * gap;
    float halfW = max(p.w, 0.5) * 0.5;
    float lineMask = 1.0 - smoothstep(halfW - 0.5, halfW + 0.5, dist);
    half3 fill = half3(0.91, 0.84, 0.65);
    params.surface().set_emissive_color(mix(fill, half3(0.0), half(lineMask)));
}
