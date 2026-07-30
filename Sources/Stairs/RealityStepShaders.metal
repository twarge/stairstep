#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Forwards the material's custom float4 to the fragment stage. Every custom
// material here pairs with this geometry modifier.
[[visible]] void stairsPassGeometry(realitykit::geometry_parameters params)
{
    params.geometry().set_custom_attribute(params.uniforms().custom_parameter());
}

// Lit model surface with the cross-section clip. custom = (nx, ny, nz, d) in
// world space; a fragment is cut when dot(world, n) > d — the same convention
// as the SceneKit shader and the snap resolver. Disabled sections pass
// d = FLT_MAX, which nothing exceeds, so there is no enabled branch to keep in
// sync. PBR constants come from the material's own properties; the 7% same-hue
// emissive lift matches the SceneKit material.
[[visible]] void stairsClipLitSurface(realitykit::surface_parameters params)
{
    float4 plane = params.geometry().custom_attribute();
    float3 world = params.geometry().world_position();
    if (dot(world, plane.xyz) > plane.w) {
        discard_fragment();
    }

    half3 tint = half3(params.material_constants().base_color_tint().rgb);
    params.surface().set_base_color(tint);
    params.surface().set_roughness(half(params.material_constants().roughness_scale()));
    params.surface().set_metallic(half(params.material_constants().metallic_scale()));
    params.surface().set_emissive_color(half3(params.material_constants().emissive_color()) * 0.07h);
}

// Screen-space 45° hatch for the section cap, phase-anchored to the model's
// origin so resizing or panning doesn't slide the pattern across the cut.
// custom = (viewW, viewH, spacingPx, lineWidthPx); the fill colour rides in the
// material's emissive colour, and the lines are black over it.
[[visible]] void stairsHatchSurface(realitykit::surface_parameters params)
{
    float4 p = params.geometry().custom_attribute();
    float4x4 worldToView = params.uniforms().world_to_view();
    float4x4 viewToProjection = params.uniforms().view_to_projection();

    float3 world = params.geometry().world_position();
    float4 clip = viewToProjection * (worldToView * float4(world, 1.0));
    float2 pixel = (clip.xy / clip.w * 0.5 + 0.5) * p.xy;

    float4 anchorClip = viewToProjection * (worldToView * float4(0.0, 0.0, 0.0, 1.0));
    float2 anchorPixel = anchorClip.w > 1e-5
        ? (anchorClip.xy / anchorClip.w * 0.5 + 0.5) * p.xy
        : float2(0.0);
    float2 delta = pixel - anchorPixel;

    float gap = max(p.z, 1.0);
    float phase = fract((delta.x + delta.y) / (gap * 1.41421356));
    float dist = min(phase, 1.0 - phase) * gap;
    float halfW = max(p.w, 0.5) * 0.5;
    float lineMask = 1.0 - smoothstep(halfW - 0.5, halfW + 0.5, dist);

    half3 fill = half3(params.material_constants().emissive_color());
    params.surface().set_emissive_color(mix(fill, half3(0.0), half(lineMask)));
}
