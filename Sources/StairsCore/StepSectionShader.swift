import Foundation
import SceneKit
import simd

#if os(macOS)
private typealias SectionScalar = CGFloat
#else
private typealias SectionScalar = Float
#endif

/// Applies the cross-section clip to mesh materials as a SceneKit surface shader
/// modifier. The clip is driven entirely by two uniforms, so the plane can be
/// dragged in real time by updating values on the existing materials — no scene
/// rebuild required. The modifier is a no-op while `sectionEnabled` is `0`.
public enum StepSectionShader {
    public static let planeUniformKey = "sectionPlane"
    public static let enabledUniformKey = "sectionEnabled"

    // `_surface.position` is in view space; transform it back to world space with
    // the frame's inverse-view matrix and discard anything on the removed side of
    // the plane. Interior walls stay visible because `install` forces the material
    // double-sided.
    //
    // NOTE: this must use `scn_frame.inverseViewTransform`, not the legacy
    // `u_inverseViewTransform` global — the latter does not exist in SceneKit's
    // Metal shader-modifier path and makes the whole modifier fail to compile,
    // which renders the geometry solid magenta.
    private static let surfaceModifier = """
    #pragma arguments
    float4 sectionPlane;
    float sectionEnabled;
    #pragma body
    if (sectionEnabled > 0.5) {
        float3 sectionWorldPosition = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        if (dot(sectionWorldPosition, sectionPlane.xyz) > sectionPlane.w) {
            discard_fragment();
        }
    }
    """

    /// Attaches the clip modifier to each material and forces double-sided
    /// rendering so cut-open interiors are visible. Idempotent.
    public static func install(on materials: [SCNMaterial]) {
        for material in materials {
            var modifiers = material.shaderModifiers ?? [:]
            modifiers[.surface] = surfaceModifier
            material.shaderModifiers = modifiers
            material.isDoubleSided = true
            material.setValue(vectorValue(SIMD4<Float>(repeating: 0)), forKey: planeUniformKey)
            material.setValue(NSNumber(value: 0.0), forKey: enabledUniformKey)
        }
    }

    /// Updates the live clip uniforms for the given plane. Cheap enough to call
    /// on every drag frame.
    public static func apply(_ plane: StepSectionPlane, center: SIMD3<Float>, to materials: [SCNMaterial]) {
        let value = vectorValue(plane.clipVector(center: center))
        let enabled = NSNumber(value: plane.isEnabled ? 1.0 : 0.0)
        for material in materials {
            material.setValue(value, forKey: planeUniformKey)
            material.setValue(enabled, forKey: enabledUniformKey)
        }
    }

    private static func vectorValue(_ vector: SIMD4<Float>) -> NSValue {
        NSValue(scnVector4: SCNVector4(
            x: SectionScalar(vector.x),
            y: SectionScalar(vector.y),
            z: SectionScalar(vector.z),
            w: SectionScalar(vector.w)
        ))
    }

    // MARK: - Section cap hatching & cutting plane

    public static let hatchColorKey = "hatchColor"
    public static let hatchSpacingKey = "hatchSpacing"
    public static let hatchLineWidthKey = "hatchLineWidth"

    /// Perpendicular gap between hatch lines, in device pixels. Public so the
    /// RealityKit canvas draws the identical pattern.
    public static let hatchSpacingPixels: Float = 10.5
    /// Hatch line thickness, in device pixels.
    public static let hatchLineWidthPixels: Float = 2

    // Draws CAD-style diagonal hatching on the cut cap, in **screen space** — the
    // lines keep the same width and spacing at any zoom, and stay at 45° on screen
    // whatever the model's orientation, which is how Fusion (and CAD section fills
    // generally) draw a cut.
    //
    // `_surface.position` is view space, so project it to clip space, divide to
    // NDC, and scale by the viewport to land in device pixels. Striping the summed
    // pixel coordinate gives 45° lines; the spacing/width uniforms are then plain
    // pixel measurements. The pattern goes into `emission` so a `.constant`
    // material shows the exact colours flat, independent of scene lighting.
    //
    // The pattern's *phase* is anchored to the model's own origin projected to
    // screen, not to the viewport corner. Spacing is constant either way, but a
    // corner-anchored pattern slides across the geometry whenever the viewport
    // resizes or the view pans; anchoring to the model keeps the hatch registered
    // to the cut face so it reads as belonging to the part.
    private static let capHatchModifier = """
    #pragma arguments
    float3 hatchColor;
    float hatchSpacing;
    float hatchLineWidth;
    #pragma body
    float2 hatchViewport = 1.0 / max(scn_frame.inverseResolution, float2(1e-6));
    float4 hatchClip = scn_frame.projectionTransform * float4(_surface.position, 1.0);
    float2 hatchPixel = (hatchClip.xy / hatchClip.w * 0.5 + 0.5) * hatchViewport;
    float4 hatchAnchorClip = scn_frame.projectionTransform * (scn_node.modelViewTransform * float4(0.0, 0.0, 0.0, 1.0));
    float2 hatchAnchorPixel = hatchAnchorClip.w > 1e-5
        ? (hatchAnchorClip.xy / hatchAnchorClip.w * 0.5 + 0.5) * hatchViewport
        : float2(0.0);
    float2 hatchDelta = hatchPixel - hatchAnchorPixel;
    // Lines of constant (x + y) run at 45°; that coordinate advances by
    // spacing * sqrt(2) between adjacent lines, so scale the period accordingly
    // and the phase converts straight back into a perpendicular pixel distance.
    float hatchGap = max(hatchSpacing, 1.0);
    float hatchPhase = fract((hatchDelta.x + hatchDelta.y) / (hatchGap * 1.41421356));
    float hatchDistance = min(hatchPhase, 1.0 - hatchPhase) * hatchGap;
    float hatchHalfWidth = max(hatchLineWidth, 0.5) * 0.5;
    float hatchLine = 1.0 - smoothstep(hatchHalfWidth - 0.5, hatchHalfWidth + 0.5, hatchDistance);
    // Black lines over the configured fill colour.
    float3 hatchOut = mix(hatchColor, float3(0.0), hatchLine);
    _surface.emission = float4(hatchOut, 1.0);
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    """

    /// A flat, double-sided material that renders the cut cap as diagonal hatching
    /// in `color`. The hatch is screen-space, so its spacing and line width are
    /// zoom-invariant and need no model-size input.
    public static func makeCapMaterial(color: PlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = color
        material.emission.contents = color
        material.shaderModifiers = [.surface: capHatchModifier]
        material.setValue(NSNumber(value: hatchSpacingPixels), forKey: hatchSpacingKey)
        material.setValue(NSNumber(value: hatchLineWidthPixels), forKey: hatchLineWidthKey)
        setHatchColor(color, on: material)
        return material
    }

    /// Live-updates the hatch colour on an existing cap material (no rebuild).
    public static func setHatchColor(_ color: PlatformColor, on material: SCNMaterial) {
        // Linear, not sRGB: this is a raw shader uniform (see stairsLinearRGBComponents).
        let rgb = color.stairsLinearRGBComponents
        material.setValue(
            NSValue(scnVector3: SCNVector3(SectionScalar(rgb.x), SectionScalar(rgb.y), SectionScalar(rgb.z))),
            forKey: hatchColorKey
        )
    }

    /// A translucent, double-sided material for the cutting-plane quad. It reads
    /// depth (so the kept solid occludes it) but doesn't write depth (so it blends
    /// cleanly), tinting whatever shows through the cut and beyond the model.
    public static func makeSectionPlaneMaterial(color: PlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        material.transparency = 0.16
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        return material
    }
}
