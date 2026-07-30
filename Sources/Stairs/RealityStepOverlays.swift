import CoreGraphics
import RealityKit
import StairsCore
import simd

/// Renders the hover highlight and the committed measurement as RealityKit
/// entities — the counterpart of `StepMeasurementController`, drawing from the
/// same `StepOverlayStyle` so the engines look identical.
///
/// Where SceneKit used per-frame constraints, this uses `BillboardComponent`
/// for camera-facing markers and a per-frame `tick(cameraPosition:)` (driven by
/// the host's scene-update subscription) for constant on-screen size.
@MainActor
final class RealityStepOverlayController {
    let highlightParent = Entity()
    let measurementParent = Entity()

    weak var snapModel: StepSnapModel?

    private var lastHighlightKey: String?
    private var lastMeasurementKey: String?

    /// Entities whose scale tracks camera distance for constant screen size.
    /// `lockY` keeps a cylinder's length in world space while its radius scales.
    private struct ScaledEntity {
        weak var entity: Entity?
        var reference: Float
        var lockY: Bool
    }

    private var scaledEntities: [ScaledEntity] = []
    private var textureCache = [String: TextureResource]()

    func install(under parent: Entity) {
        if highlightParent.parent == nil { parent.addChild(highlightParent) }
        if measurementParent.parent == nil { parent.addChild(measurementParent) }
    }

    /// Per-frame constant-size scaling; called from the host's update event.
    func tick(cameraPosition: SIMD3<Float>) {
        scaledEntities.removeAll { $0.entity == nil }
        for entry in scaledEntities {
            guard let entity = entry.entity, entity.parent != nil else { continue }
            let distance = simd_distance(cameraPosition, entity.position(relativeTo: nil))
            let factor = max(distance / max(entry.reference, 1e-5), 1e-4)
            entity.scale = SIMD3<Float>(factor, entry.lockY ? 1 : factor, factor)
        }
    }

    // MARK: - Highlight

    func clearHighlight() {
        guard lastHighlightKey != nil || !highlightParent.children.isEmpty else { return }
        lastHighlightKey = nil
        highlightParent.children.removeAll()
    }

    func applyHighlight(_ result: StepSnapResult?, largestDimension: Float, sectionClip: SIMD4<Float>?) {
        let key = highlightKey(result)
        if key == lastHighlightKey { return }
        lastHighlightKey = key
        highlightParent.children.removeAll()
        guard let result else { return }

        let reference = largestDimension * StepOverlayStyle.sizeReferenceFactor
        switch result.kind {
        case .vertex:
            addSphere(
                at: result.point,
                radius: max(largestDimension * 0.016, 0.001),
                color: StepOverlayStyle.highlight,
                reference: reference,
                under: highlightParent
            )
        case .edge:
            if let edge = result.edge {
                addCylinder(
                    from: edge.start,
                    to: edge.end,
                    radius: max(largestDimension * 0.006, 0.0006),
                    color: StepOverlayStyle.highlight,
                    reference: reference,
                    under: highlightParent
                )
            }
        case .face:
            if let region = result.regionID {
                addFaceOverlay(region: region, sectionClip: sectionClip, under: highlightParent)
            }
        }
    }

    // MARK: - Measurement

    func applyMeasurement(_ measurement: StepMeasurement, largestDimension: Float) {
        let key = measurementKey(measurement)
        if key == lastMeasurementKey { return }
        lastMeasurementKey = key
        measurementParent.children.removeAll()

        guard let start = measurement.start else { return }
        let reference = largestDimension * StepOverlayStyle.sizeReferenceFactor
        let markerDiameter = max(largestDimension * 0.034, 0.003)
        let lineRadius = max(largestDimension * 0.004, 0.0005)
        let badgeHeight = max(largestDimension * 0.05, 0.008)

        addMarker(1, at: start.position, diameter: markerDiameter, reference: reference)

        if measurement.end == nil, case .edgeLength(let distance, let segment)? = measurement.readout {
            addCylinder(from: segment.start, to: segment.end, radius: lineRadius, color: StepOverlayStyle.measurement, reference: reference, under: measurementParent)
            addBadge(
                text: StepOverlayStyle.formatLength(distance),
                at: (segment.start + segment.end) / 2,
                height: badgeHeight,
                fill: StepOverlayStyle.measurement.cgColor,
                reference: reference
            )
        }

        guard let end = measurement.end, let readout = measurement.readout else { return }
        switch readout {
        case .edgeLength:
            break
        case .pointToPoint(let distance, _):
            addMarker(2, at: end.position, diameter: markerDiameter, reference: reference)
            addCylinder(from: start.position, to: end.position, radius: lineRadius, color: StepOverlayStyle.measurement, reference: reference, under: measurementParent)
            let legRadius = max(largestDimension * 0.0022, 0.0004)
            let cornerX = SIMD3<Float>(end.position.x, start.position.y, start.position.z)
            let cornerXY = SIMD3<Float>(end.position.x, end.position.y, start.position.z)
            for (a, b, color) in [
                (start.position, cornerX, StepOverlayStyle.axisX),
                (cornerX, cornerXY, StepOverlayStyle.axisY),
                (cornerXY, end.position, StepOverlayStyle.axisZ),
            ] {
                addCylinder(from: a, to: b, radius: legRadius, color: color, reference: reference, under: measurementParent)
            }
            addBadge(
                text: StepOverlayStyle.formatLength(distance),
                at: (start.position + end.position) / 2,
                height: badgeHeight,
                fill: StepOverlayStyle.measurement.cgColor,
                reference: reference
            )
        case .normalDistance(let distance, let from, let to):
            addMarker(2, at: to, diameter: markerDiameter, reference: reference)
            addCylinder(from: from, to: to, radius: lineRadius, color: StepOverlayStyle.measurement, reference: reference, under: measurementParent)
            addBadge(
                text: StepOverlayStyle.formatLength(distance),
                at: (from + to) / 2,
                height: badgeHeight,
                fill: StepOverlayStyle.measurement.cgColor,
                reference: reference
            )
        case .notParallel(let angleDegrees):
            addMarker(2, at: end.position, diameter: markerDiameter, reference: reference)
            let angle = angleDegrees.formatted(.number.precision(.fractionLength(0...1)))
            addBadge(
                text: "Not parallel · \(angle)°",
                at: (start.position + end.position) / 2,
                height: badgeHeight,
                fill: StepOverlayStyle.warningFill,
                reference: reference
            )
        }
    }

    // MARK: - Builders

    private func register(_ entity: Entity, reference: Float, lockY: Bool) {
        scaledEntities.append(ScaledEntity(entity: entity, reference: reference, lockY: lockY))
    }

    private func unlit(_ color: PlatformColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    private func addSphere(at position: SIMD3<Float>, radius: Float, color: PlatformColor, reference: Float, under parent: Entity) {
        let entity = ModelEntity(mesh: .generateSphere(radius: radius), materials: [unlit(color)])
        entity.position = position
        parent.addChild(entity)
        register(entity, reference: reference, lockY: false)
    }

    private func addCylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, color: PlatformColor, reference: Float, under parent: Entity) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return }
        let entity = ModelEntity(
            mesh: .generateCylinder(height: length, radius: radius),
            materials: [unlit(color)]
        )
        entity.position = (start + end) / 2
        // The cylinder runs along +Y; rotate it onto the segment direction.
        let direction = delta / length
        let yAxis = SIMD3<Float>(0, 1, 0)
        let axis = simd_cross(yAxis, direction)
        let axisLength = simd_length(axis)
        if axisLength < 1e-5 {
            if direction.y < 0 {
                entity.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            }
        } else {
            let angle = acos(simd_clamp(simd_dot(yAxis, direction), -1, 1))
            entity.orientation = simd_quatf(angle: angle, axis: axis / axisLength)
        }
        parent.addChild(entity)
        register(entity, reference: reference, lockY: true)
    }

    private func addFaceOverlay(region: Int, sectionClip: SIMD4<Float>?, under parent: Entity) {
        let raw = snapModel?.regionTriangleVertices(region) ?? []
        let positions = sectionClip.map { StepSectionClip.clipTriangles(raw, by: $0) } ?? raw
        guard positions.count >= 3 else { return }

        var descriptor = MeshDescriptor(name: "Face highlight")
        // Both windings so the overlay reads from either side.
        var doubled = positions
        var triangle = 0
        while triangle + 2 < positions.count {
            doubled.append(positions[triangle + 2])
            doubled.append(positions[triangle + 1])
            doubled.append(positions[triangle])
            triangle += 3
        }
        descriptor.positions = MeshBuffer(doubled)
        descriptor.primitives = .triangles(Array(0..<UInt32(doubled.count)))
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return }

        var material = UnlitMaterial(color: StepOverlayStyle.highlight)
        material.blending = .transparent(opacity: 0.28)
        let entity = ModelEntity(mesh: resource, materials: [material])
        parent.addChild(entity)
    }

    private func addMarker(_ number: Int, at position: SIMD3<Float>, diameter: Float, reference: Float) {
        guard let texture = cachedTexture(
            key: "marker-\(number)",
            image: StepOverlayStyle.markerImage(number, fill: StepOverlayStyle.measurement.cgColor, textColor: StepOverlayStyle.whiteText)
        ) else {
            addSphere(at: position, radius: diameter / 2, color: StepOverlayStyle.measurement, reference: reference, under: measurementParent)
            return
        }
        addTexturedPlane(texture: texture, at: position, width: diameter, height: diameter, reference: reference)
    }

    private func addBadge(text: String, at position: SIMD3<Float>, height: Float, fill: CGColor, reference: Float) {
        guard let image = StepOverlayStyle.badgeImage(text: text, fill: fill, textColor: StepOverlayStyle.whiteText),
              let texture = cachedTexture(key: "badge-\(text)", image: image) else { return }
        let aspect = Float(texture.width) / Float(max(texture.height, 1))
        addTexturedPlane(texture: texture, at: position, width: height * aspect, height: height, reference: reference)
    }

    private func addTexturedPlane(texture: TextureResource, at position: SIMD3<Float>, width: Float, height: Float, reference: Float) {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        material.faceCulling = .none
        let entity = ModelEntity(
            mesh: .generatePlane(width: width, height: height),
            materials: [material]
        )
        entity.position = position
        entity.components.set(BillboardComponent())
        measurementParent.addChild(entity)
        register(entity, reference: reference, lockY: false)
    }

    private func cachedTexture(key: String, image: CGImage?) -> TextureResource? {
        if let cached = textureCache[key] { return cached }
        guard let image,
              let texture = try? TextureResource(
                  image: image,
                  options: .init(semantic: .color)
              ) else { return nil }
        textureCache[key] = texture
        return texture
    }

    // MARK: - Keys (feature identity, so hover and drags don't rebuild per frame)

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

    private func measurementKey(_ measurement: StepMeasurement) -> String {
        func point(_ p: StepMeasurePoint?) -> String {
            guard let p else { return "-" }
            var key = String(format: "%.4f,%.4f,%.4f", p.position.x, p.position.y, p.position.z)
            if let plane = p.plane {
                key += String(format: "|n%.3f,%.3f,%.3f", plane.normal.x, plane.normal.y, plane.normal.z)
            }
            if let line = p.line {
                key += String(format: "|d%.3f,%.3f,%.3f", line.direction.x, line.direction.y, line.direction.z)
            }
            if let edge = p.edge {
                key += String(format: "|e%.3f,%.3f,%.3f>%.3f,%.3f,%.3f",
                              edge.start.x, edge.start.y, edge.start.z, edge.end.x, edge.end.y, edge.end.z)
            }
            return key
        }
        return "\(point(measurement.start))|\(point(measurement.end))"
    }
}
