import CoreGraphics
import CoreText
import Foundation
import SceneKit
import StairsCore
import simd

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(macOS)
private typealias OverlayScalar = CGFloat
#else
private typealias OverlayScalar = Float
#endif

/// SceneKit's side of the ``StepSnapScene`` seam. The engine specifics — node
/// names, category masks, hit-test options — live here, so the resolver in
/// StairsCore stays engine-free and a RealityKit host only has to conform.
// Fully qualified (SE-0364): silences Xcode's retroactive-conformance warning
// where the targets are separate modules, while staying legal under SwiftPM
// where both live in one package and `@retroactive` is rejected.
extension SceneKit.SCNView: StairsCore.StepSnapScene {
    public func snapScreenPoint(for worldPoint: SIMD3<Float>) -> SIMD2<Float>? {
        let projected = projectPoint(SCNVector3(worldPoint))
        // z outside [0, 1] means the point is outside the view frustum (e.g. behind).
        guard projected.z >= 0, projected.z <= 1 else {
            return nil
        }
        return SIMD2<Float>(Float(projected.x), Float(projected.y))
    }

    public func snapSurfaceHits(at viewPoint: CGPoint) -> [StepSnapSurfaceHit] {
        let options: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            // Every crossing, nearest first: the closest hit alone isn't enough
            // once the resolver has to skip clipped-away geometry.
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
            // Exclude the measurement overlays and the cutting plane: a highlight
            // drawn on top of the target must not intercept the ray, or the cursor
            // gets a dead zone right over the vertex/edge it's trying to snap to.
            // The section cap stays hittable so its outline can be snapped to.
            .categoryBitMask: ~StepSectionCapController.nonSnappableCategoryBitMask
        ]
        return hitTest(viewPoint, options: options).compactMap { hit in
            let world = SIMD3<Float>(
                Float(hit.worldCoordinates.x),
                Float(hit.worldCoordinates.y),
                Float(hit.worldCoordinates.z)
            )
            switch hit.node.name {
            case StepSceneFactory.meshNodeName:
                return StepSnapSurfaceHit(surface: .model, worldPoint: world)
            case StepSectionCapController.capNodeName:
                return StepSnapSurfaceHit(surface: .sectionCap, worldPoint: world)
            default:
                return nil // grid, floor, axes: not snappable
            }
        }
    }

    public var snapCameraPosition: SIMD3<Float>? {
        pointOfView.map { $0.presentation.simdWorldPosition }
    }
}

/// Shared appearance of the measurement overlays — colours, sizes, and the
/// CoreGraphics marker/badge renderers — used by both the SceneKit and the
/// RealityKit controllers so the two engines cannot drift apart.
enum StepOverlayStyle {
    static var measurement: PlatformColor { PlatformColor.stairsSelection }
    static let highlight = PlatformColor.systemTeal
    static let axisX = PlatformColor(red: 0.95, green: 0.20, blue: 0.16, alpha: 1)
    static let axisY = PlatformColor(red: 0.20, green: 0.78, blue: 0.30, alpha: 1)
    static let axisZ = PlatformColor(red: 0.22, green: 0.48, blue: 1.00, alpha: 1)
    static let warningFill = CGColor(red: 0.80, green: 0.18, blue: 0.14, alpha: 0.95)
    static let whiteText = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// Camera distance (as a multiple of the model's largest dimension) at which
    /// overlay markers render at their design size — the default framing.
    static let sizeReferenceFactor: Float = 1.9

    static func markerImage(_ number: Int, fill: CGColor, textColor: CGColor) -> CGImage? {
        let size = 128
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let inset: CGFloat = 5
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2))

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, CGFloat(size) * 0.6, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: textColor] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, "\(number)" as CFString, attributes) else {
            return context.makeImage()
        }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        context.textPosition = CGPoint(x: (CGFloat(size) - textWidth) / 2, y: (CGFloat(size) - (ascent + descent)) / 2 + descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }
    /// Renders the pill (rounded-rect background + centered text) to a CGImage
    /// using CoreText/CoreGraphics — cross-platform, no AppKit/UIKit.
    static func badgeImage(text: String, fill: CGColor, textColor: CGColor) -> CGImage? {
        let fontSize: CGFloat = 44
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent
        let padX = fontSize * 0.55
        let padY = fontSize * 0.30
        let width = Int((textWidth + padX * 2).rounded(.up))
        let height = Int((textHeight + padY * 2).rounded(.up))
        guard width > 0, height > 0 else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let inset: CGFloat = 1
        let rect = CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
        let radius = rect.height * 0.42
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()

        context.textPosition = CGPoint(
            x: (CGFloat(width) - textWidth) / 2,
            y: (CGFloat(height) - textHeight) / 2 + descent
        )
        CTLineDraw(line, context)
        return context.makeImage()
    }
    static func formatLength(_ millimeters: Float) -> String {
        let value = Double(millimeters)
        if value >= 1_000 {
            return "\((value / 1_000).formatted(.number.precision(.fractionLength(0...2)))) m"
        }
        if value >= 1 {
            return "\(value.formatted(.number.precision(.fractionLength(0...3)))) mm"
        }
        return "\((value * 1_000).formatted(.number.precision(.fractionLength(0...1)))) µm"
    }
}

/// Renders the committed measurement (endpoint markers, connecting line, and a
/// billboarded distance label) plus the live hover highlight, on the live scene
/// without triggering a scene rebuild. Main-actor; parallels the section cap
/// controller.
@MainActor
final class StepMeasurementController {
    private static let measurementNodeName = "Measurement"
    private static let highlightNodeName = "Snap highlight"

    private let measurementColor = StepOverlayStyle.measurement
    private let highlightColor = StepOverlayStyle.highlight
    private static let axisXColor = StepOverlayStyle.axisX
    private static let axisYColor = StepOverlayStyle.axisY
    private static let axisZColor = StepOverlayStyle.axisZ
    private static let warningFill = StepOverlayStyle.warningFill
    private static let whiteText = StepOverlayStyle.whiteText
    private static let sizeReferenceFactor = StepOverlayStyle.sizeReferenceFactor

    /// Every overlay node (markers, lines, highlights, badge) carries this
    /// category so the snap hit test can exclude them. Without it, an overlay
    /// drawn on top of a vertex/edge becomes the closest hit and the snap ray
    /// never reaches the mesh — creating a dead zone right over the target.
    static let overlayCategoryBitMask = 1 << 20

    private var lastMeasurementKey: String?
    private var lastHighlightKey: String?

    func applyMeasurement(_ measurement: StepMeasurement, scene: SCNScene, largestDimension: Float, isDarkMode: Bool, cameraNode: SCNNode?) {
        let key = measurementKey(measurement, isDarkMode: isDarkMode)
        if key == lastMeasurementKey, scene.rootNode.childNode(withName: Self.measurementNodeName, recursively: false) != nil {
            return
        }
        lastMeasurementKey = key

        scene.rootNode.childNode(withName: Self.measurementNodeName, recursively: false)?.removeFromParentNode()
        guard let start = measurement.start else {
            return
        }

        let container = SCNNode()
        container.name = Self.measurementNodeName

        // Overlay markers keep a constant on-screen size (see constantSizeConstraint);
        // these world sizes are their apparent size at the default framing distance.
        let reference = largestDimension * Self.sizeReferenceFactor
        let markerDiameter = max(largestDimension * 0.034, 0.003)
        container.addChildNode(numberedMarker(1, at: start.position, diameter: markerDiameter, reference: reference, cameraNode: cameraNode))

        let lineRadius = CGFloat(max(largestDimension * 0.004, 0.0005))
        let badgeHeight = max(largestDimension * 0.05, 0.008)
        let lineFill = measurementColor.cgColor

        // One edge selected: draw it and label its own length, before a second
        // selection turns the readout into a distance.
        if measurement.end == nil, case .edgeLength(let distance, let segment)? = measurement.readout {
            if let line = cylinder(from: segment.start, to: segment.end, radius: lineRadius, color: measurementColor, reference: reference, cameraNode: cameraNode) {
                container.addChildNode(line)
            }
            container.addChildNode(badge(
                text: formatLength(distance),
                at: (segment.start + segment.end) / 2,
                alongDirection: segment.end - segment.start,
                worldHeight: badgeHeight,
                fill: lineFill,
                textColor: Self.whiteText,
                reference: reference,
                cameraNode: cameraNode
            ))
        }

        if let end = measurement.end, let readout = measurement.readout {
            switch readout {
            case .edgeLength:
                break // only meaningful before a second selection
            case .pointToPoint(let distance, _):
                container.addChildNode(numberedMarker(2, at: end.position, diameter: markerDiameter, reference: reference, cameraNode: cameraNode))
                if let line = cylinder(from: start.position, to: end.position, radius: lineRadius, color: measurementColor, reference: reference, cameraNode: cameraNode) {
                    container.addChildNode(line)
                }
                // X/Y/Z extent legs: an axis-aligned staircase from start to end.
                let legRadius = CGFloat(max(largestDimension * 0.0022, 0.0004))
                let cornerX = SIMD3<Float>(end.position.x, start.position.y, start.position.z)
                let cornerXY = SIMD3<Float>(end.position.x, end.position.y, start.position.z)
                for (a, b, color) in [
                    (start.position, cornerX, Self.axisXColor),
                    (cornerX, cornerXY, Self.axisYColor),
                    (cornerXY, end.position, Self.axisZColor)
                ] {
                    if let leg = cylinder(from: a, to: b, radius: legRadius, color: color, reference: reference, cameraNode: cameraNode) {
                        container.addChildNode(leg)
                    }
                }
                container.addChildNode(badge(text: formatLength(distance), at: (start.position + end.position) / 2, alongDirection: end.position - start.position, worldHeight: badgeHeight, fill: lineFill, textColor: Self.whiteText, reference: reference, cameraNode: cameraNode))

            case .normalDistance(let distance, let from, let to):
                // The perpendicular between the two surfaces/edges.
                container.addChildNode(numberedMarker(2, at: to, diameter: markerDiameter, reference: reference, cameraNode: cameraNode))
                if let line = cylinder(from: from, to: to, radius: lineRadius, color: measurementColor, reference: reference, cameraNode: cameraNode) {
                    container.addChildNode(line)
                }
                container.addChildNode(badge(text: formatLength(distance), at: (from + to) / 2, alongDirection: to - from, worldHeight: badgeHeight, fill: lineFill, textColor: Self.whiteText, reference: reference, cameraNode: cameraNode))

            case .notParallel(let angleDegrees):
                container.addChildNode(numberedMarker(2, at: end.position, diameter: markerDiameter, reference: reference, cameraNode: cameraNode))
                let angle = angleDegrees.formatted(.number.precision(.fractionLength(0...1)))
                container.addChildNode(badge(text: "Not parallel · \(angle)°", at: (start.position + end.position) / 2, alongDirection: end.position - start.position, worldHeight: badgeHeight, fill: Self.warningFill, textColor: Self.whiteText, reference: reference, cameraNode: cameraNode))
            }
        }

        scene.rootNode.addChildNode(container)
    }

    func applyHighlight(
        _ result: StepSnapResult?,
        scene: SCNScene,
        largestDimension: Float,
        cameraNode: SCNNode?,
        sectionClip: SIMD4<Float>? = nil
    ) {
        // The key is the feature's identity (which vertex / edge / face), not the
        // exact hit point — so sliding the cursor across the same feature doesn't
        // tear down and rebuild the highlight every frame (which flickers).
        let key = highlightKey(result)
        if key == lastHighlightKey {
            return
        }
        lastHighlightKey = key

        scene.rootNode.childNode(withName: Self.highlightNodeName, recursively: false)?.removeFromParentNode()
        guard let result else {
            return
        }

        let container = SCNNode()
        container.name = Self.highlightNodeName
        let reference = largestDimension * Self.sizeReferenceFactor

        switch result.kind {
        case .vertex:
            container.addChildNode(sphere(at: result.point, radius: CGFloat(max(largestDimension * 0.016, 0.001)), color: highlightColor, reference: reference, cameraNode: cameraNode))
        case .edge:
            if let edge = result.edge,
               let node = cylinder(from: edge.start, to: edge.end, radius: CGFloat(max(largestDimension * 0.006, 0.0006)), color: highlightColor, reference: reference, cameraNode: cameraNode) {
                container.addChildNode(node)
            }
        case .face:
            if let region = result.regionID {
                container.addChildNode(faceOverlay(
                    regionID: region,
                    largestDimension: largestDimension,
                    sectionClip: sectionClip
                ))
            }
        }

        scene.rootNode.addChildNode(container)
    }

    func clear(scene: SCNScene?) {
        scene?.rootNode.childNode(withName: Self.highlightNodeName, recursively: false)?.removeFromParentNode()
        lastHighlightKey = nil
    }

    // Set by the canvas each configure so face overlays can be built from geometry.
    weak var snapModel: StepSnapModel?

    // MARK: - Node builders

    private func sphere(at position: SIMD3<Float>, radius: CGFloat, color: PlatformColor, reference: Float, cameraNode: SCNNode?) -> SCNNode {
        let geometry = SCNSphere(radius: radius)
        geometry.firstMaterial = overlayMaterial(color)
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(position)
        node.renderingOrder = 1_000
        node.castsShadow = false
        node.categoryBitMask = Self.overlayCategoryBitMask
        node.constraints = [Self.constantSizeConstraint(reference: reference, lockYAxis: false, cameraNode: cameraNode)]
        return node
    }

    private func cylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: CGFloat, color: PlatformColor, reference: Float, cameraNode: SCNNode?) -> SCNNode? {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return nil }

        let geometry = SCNCylinder(radius: radius, height: CGFloat(length))
        geometry.firstMaterial = overlayMaterial(color)
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3((start + end) / 2)
        node.renderingOrder = 1_000
        node.castsShadow = false

        // SCNCylinder runs along +Y; rotate it onto the segment direction.
        let direction = delta / length
        let yAxis = SIMD3<Float>(0, 1, 0)
        let axis = simd_cross(yAxis, direction)
        let axisLength = simd_length(axis)
        if axisLength < 1e-5 {
            if direction.y < 0 {
                node.rotation = SCNVector4(1, 0, 0, OverlayScalar.pi)
            }
        } else {
            let angle = acos(simd_clamp(simd_dot(yAxis, direction), -1, 1))
            let unit = axis / axisLength
            node.rotation = SCNVector4(OverlayScalar(unit.x), OverlayScalar(unit.y), OverlayScalar(unit.z), OverlayScalar(angle))
        }
        node.categoryBitMask = Self.overlayCategoryBitMask
        // Hold a constant on-screen thickness while the length stays in world space
        // (lockYAxis keeps the cylinder's +Y length; only its radius rescales).
        node.constraints = [Self.constantSizeConstraint(reference: reference, lockYAxis: true, cameraNode: cameraNode)]
        return node
    }

    private func faceOverlay(regionID: Int, largestDimension: Float, sectionClip: SIMD4<Float>?) -> SCNNode {
        let region = snapModel?.regionTriangleVertices(regionID) ?? []
        // Trim to the visible part, or the highlight paints the whole face —
        // including the piece the section removed, which floats past the cut.
        let positions = sectionClip.map { StepSectionClip.clipTriangles(region, by: $0) } ?? region
        guard positions.count >= 3 else {
            return SCNNode()
        }
        let vertices = positions.map { SCNVector3($0) }
        let indices = (0..<UInt32(positions.count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: positions.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        let material = overlayMaterial(highlightColor.withAlphaComponent(0.28))
        material.isDoubleSided = true
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 999
        node.castsShadow = false
        node.categoryBitMask = Self.overlayCategoryBitMask
        return node
    }

    /// A small billboarded dot carrying the endpoint's number (1 or 2).
    private func numberedMarker(_ number: Int, at position: SIMD3<Float>, diameter: Float, reference: Float, cameraNode: SCNNode?) -> SCNNode {
        guard let image = StepOverlayStyle.markerImage(number, fill: measurementColor.cgColor, textColor: Self.whiteText) else {
            return sphere(at: position, radius: CGFloat(max(diameter / 2, 0.001)), color: measurementColor, reference: reference, cameraNode: cameraNode)
        }
        let plane = SCNPlane(width: CGFloat(diameter), height: CGFloat(diameter))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material

        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(position)
        // Face the camera (billboard), then hold a constant on-screen size.
        node.constraints = [SCNBillboardConstraint(), Self.constantSizeConstraint(reference: reference, lockYAxis: false, cameraNode: cameraNode)]
        node.renderingOrder = 1_003
        node.castsShadow = false
        node.categoryBitMask = Self.overlayCategoryBitMask
        return node
    }


    /// A rounded-rect "pill" badge showing the distance. It squarely faces the
    /// camera (so it's always readable) but spins within the screen plane so its
    /// long axis appears parallel to the measurement line from the viewer's
    /// perspective, and holds a constant on-screen size.
    private func badge(
        text: String,
        at position: SIMD3<Float>,
        alongDirection direction: SIMD3<Float>,
        worldHeight: Float,
        fill: CGColor,
        textColor: CGColor,
        reference: Float,
        cameraNode: SCNNode?
    ) -> SCNNode {
        guard let image = StepOverlayStyle.badgeImage(text: text, fill: fill, textColor: textColor) else {
            return SCNNode()
        }
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let plane = SCNPlane(width: CGFloat(worldHeight) * aspect, height: CGFloat(worldHeight))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material

        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(position)
        // Above the endpoint markers and highlights so the label is never occluded.
        node.renderingOrder = 1_010
        node.castsShadow = false
        node.categoryBitMask = Self.overlayCategoryBitMask
        let axis = simd_length(direction) > 0 ? simd_normalize(direction) : SIMD3<Float>(1, 0, 0)
        node.constraints = [Self.badgeOrientationConstraint(alongLine: axis, reference: reference, cameraNode: cameraNode)]
        return node
    }

    /// Orients the badge to face the camera while rolling it about the view axis
    /// so its long (text) axis lines up with the measurement line as projected on
    /// screen, and scales it to a constant on-screen size — all in one transform
    /// so the billboard and the roll can't fight each other.
    ///
    /// `nonisolated`: SceneKit runs constraint blocks on its render thread (see
    /// `constantSizeConstraint`).
    private nonisolated static func badgeOrientationConstraint(alongLine lineAxis: SIMD3<Float>, reference: Float, cameraNode: SCNNode?) -> SCNTransformConstraint {
        SCNTransformConstraint(inWorldSpace: false) { [weak cameraNode] node, transform in
            guard let cameraNode else { return transform }
            let toCamera = cameraNode.presentation.simdWorldPosition - node.presentation.simdWorldPosition
            let distance = simd_length(toCamera)
            guard distance > 1e-6 else { return transform }
            let zAxis = toCamera / distance // billboard normal: straight at the camera
            // The badge's X axis is the line direction flattened into the plane that
            // faces the camera, so on screen the pill runs parallel to the line.
            var xAxis = lineAxis - simd_dot(lineAxis, zAxis) * zAxis
            if simd_length(xAxis) < 1e-4 {
                // Line points almost at the camera; fall back to a stable screen axis.
                xAxis = simd_cross(SIMD3<Float>(0, 1, 0), zAxis)
                if simd_length(xAxis) < 1e-4 {
                    xAxis = simd_cross(SIMD3<Float>(1, 0, 0), zAxis)
                }
            }
            xAxis = simd_normalize(xAxis)
            var yAxis = simd_normalize(simd_cross(zAxis, xAxis))
            // Keep the label upright: if its up points downward on screen, spin it
            // 180° about the view axis — still parallel to the line, but not upside
            // down (this happens whenever the line runs right-to-left on screen).
            let cameraUp = cameraNode.presentation.simdWorldTransform.columns.1
            if simd_dot(yAxis, SIMD3<Float>(cameraUp.x, cameraUp.y, cameraUp.z)) < 0 {
                xAxis = -xAxis
                yAxis = -yAxis
            }
            let scale = max(distance / max(reference, 1e-5), 1e-4)
            var m = simd_float4x4(transform)
            m.columns.0 = SIMD4<Float>(xAxis * scale, 0)
            m.columns.1 = SIMD4<Float>(yAxis * scale, 0)
            m.columns.2 = SIMD4<Float>(zAxis * scale, 0)
            return SCNMatrix4(m)
        }
    }

    /// Scales `node` each frame so its on-screen size stays constant as the camera
    /// dollies in and out: a perspective object's screen size is proportional to
    /// worldSize / distance, so we set worldSize proportional to distance. It only
    /// rescales the basis-vector lengths, so it composes after a billboard (which
    /// sets orientation). `lockYAxis` leaves the local +Y length untouched, so a
    /// cylinder's length stays in world space while only its radius rescales.
    ///
    /// `nonisolated` is essential: SceneKit evaluates constraint blocks on its
    /// render thread, but this module defaults to `@MainActor`, which would
    /// otherwise make the closure main-actor-isolated and trap when SceneKit runs
    /// it off-main.
    private nonisolated static func constantSizeConstraint(reference: Float, lockYAxis: Bool, cameraNode: SCNNode?) -> SCNTransformConstraint {
        SCNTransformConstraint(inWorldSpace: false) { [weak cameraNode] node, transform in
            guard let cameraNode else { return transform }
            let distance = simd_length(cameraNode.presentation.simdWorldPosition - node.presentation.simdWorldPosition)
            let scale = max(distance / max(reference, 1e-5), 1e-4)
            var m = simd_float4x4(transform)
            m.columns.0 = rescaled(m.columns.0, to: scale)
            if !lockYAxis {
                m.columns.1 = rescaled(m.columns.1, to: scale)
            }
            m.columns.2 = rescaled(m.columns.2, to: scale)
            return SCNMatrix4(m)
        }
    }

    /// Returns `column` with its xyz direction preserved but its length set to
    /// `length` (its w component is left unchanged).
    private nonisolated static func rescaled(_ column: SIMD4<Float>, to length: Float) -> SIMD4<Float> {
        let v = SIMD3<Float>(column.x, column.y, column.z)
        let currentLength = simd_length(v)
        guard currentLength > 1e-6 else { return column }
        let scaled = v * (length / currentLength)
        return SIMD4<Float>(scaled.x, scaled.y, scaled.z, column.w)
    }


    private func overlayMaterial(_ color: PlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    // MARK: - Change keys

    private func measurementKey(_ measurement: StepMeasurement, isDarkMode: Bool) -> String {
        func point(_ p: StepMeasurePoint?) -> String {
            guard let p else { return "-" }
            let base = String(format: "%.4f,%.4f,%.4f", p.position.x, p.position.y, p.position.z)
            if let plane = p.plane {
                return base + String(format: "|n%.3f,%.3f,%.3f", plane.normal.x, plane.normal.y, plane.normal.z)
            }
            if let line = p.line {
                var key = base + String(format: "|d%.3f,%.3f,%.3f", line.direction.x, line.direction.y, line.direction.z)
                if let edge = p.edge {
                    // Include the segment: a single selection now draws the edge and
                    // its length, so switching edges has to rebuild the overlay.
                    key += String(format: "|e%.3f,%.3f,%.3f>%.3f,%.3f,%.3f",
                                  edge.start.x, edge.start.y, edge.start.z,
                                  edge.end.x, edge.end.y, edge.end.z)
                }
                return key
            }
            return base
        }
        return "\(point(measurement.start))|\(point(measurement.end))|\(isDarkMode)"
    }

    private func highlightKey(_ result: StepSnapResult?) -> String {
        guard let result else { return "none" }
        switch result.kind {
        case .vertex:
            return "v|" + String(format: "%.4f,%.4f,%.4f", result.point.x, result.point.y, result.point.z)
        case .edge:
            guard let e = result.edge else { return "e|?" }
            return "e|" + String(format: "%.4f,%.4f,%.4f>%.4f,%.4f,%.4f", e.start.x, e.start.y, e.start.z, e.end.x, e.end.y, e.end.z)
        case .face:
            return "f|" + (result.regionID.map(String.init) ?? "-")
        }
    }
}

private func formatLength(_ millimeters: Float) -> String {
    StepOverlayStyle.formatLength(millimeters)
}
