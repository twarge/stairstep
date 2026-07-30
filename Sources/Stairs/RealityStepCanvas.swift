import Combine
import RealityKit
import StairsCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Experimental RealityKit viewer, selectable from the View menu. The engine
/// port in progress: it renders the model with the SceneKit factory's grouping,
/// framing, and decorations (grid, axes, floor, STEP colors, wireframe), takes
/// the full orbit/pan/zoom input set, and conforms to ``StepSnapScene`` so the
/// measurement brain works against it unchanged. Sections and measurement
/// overlays still come from the SceneKit canvas.
struct RealityStepCanvas: View {
    var mesh: StepTriangleMesh
    var options: StepSceneOptions
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var projection: StepCameraProjection = .perspective
    var resetID = UUID()
    var primaryViewRequest: StepPrimaryViewRequest?
    var section = StepSectionPlane()
    var sectionColor: PlatformColor = StairsSectionColor.fallback
    var measurement = StepMeasurement()
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void = { _ in }
    var onMeasureEscape: () -> Void = {}
    @Binding var cameraState: StepSceneCameraState?

    var body: some View {
        RealityStepHostRepresentable(
            mesh: mesh,
            options: options,
            isDarkMode: isDarkMode,
            reverseHorizontalRotation: reverseHorizontalRotation,
            reverseVerticalRotation: reverseVerticalRotation,
            projection: projection,
            resetID: resetID,
            primaryViewRequest: primaryViewRequest,
            section: section,
            sectionColor: sectionColor,
            measurement: measurement,
            snapModel: snapModel,
            onMeasurePointPicked: onMeasurePointPicked,
            onMeasureEscape: onMeasureEscape,
            cameraState: $cameraState
        )
    }
}

/// Collision groups mirror the SceneKit category masks: the model is the only
/// raycast target today; overlays and decorations will get their own groups as
/// they port, exactly as they carry categories now.
enum RealityStepCollision {
    static let model = CollisionGroup(rawValue: 1 << 0)
    static let sectionCap = CollisionGroup(rawValue: 1 << 1)
}

/// Writes camera-state reports back into the SwiftUI binding, exactly like the
/// SceneKit canvas coordinator: reports come from input events (never from the
/// update pass), and identical states are dropped to avoid update loops.
final class RealityStepCameraCoordinator {
    var cameraState: Binding<StepSceneCameraState?>

    init(cameraState: Binding<StepSceneCameraState?>) {
        self.cameraState = cameraState
    }

    func updateCameraState(_ state: StepSceneCameraState?) {
        guard cameraState.wrappedValue != state else {
            return
        }
        cameraState.wrappedValue = state
    }
}

#if os(macOS)
private struct RealityStepHostRepresentable: NSViewRepresentable {
    var mesh: StepTriangleMesh
    var options: StepSceneOptions
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var projection: StepCameraProjection
    var resetID: UUID
    var primaryViewRequest: StepPrimaryViewRequest?
    var section: StepSectionPlane
    var sectionColor: PlatformColor
    var measurement: StepMeasurement
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void
    var onMeasureEscape: () -> Void
    @Binding var cameraState: StepSceneCameraState?

    func makeCoordinator() -> RealityStepCameraCoordinator {
        RealityStepCameraCoordinator(cameraState: $cameraState)
    }

    func makeNSView(context: Context) -> RealityStepHostView {
        let view = RealityStepHostView(frame: .zero)
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.seedPrimaryViewRequest(primaryViewRequest)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: RealityStepHostView, context: Context) {
        context.coordinator.cameraState = $cameraState
        configure(nsView)
    }

    private func configure(_ view: RealityStepHostView) {
        view.reverseHorizontalRotation = reverseHorizontalRotation
        view.reverseVerticalRotation = reverseVerticalRotation
        view.onMeasurePointPicked = onMeasurePointPicked
        view.onMeasureEscape = onMeasureEscape
        view.apply(
            mesh: mesh,
            options: options,
            isDarkMode: isDarkMode,
            section: section,
            sectionColor: sectionColor,
            measurement: measurement,
            snapModel: snapModel
        )
        view.applyPrimaryViewRequest(primaryViewRequest)
        view.applyCameraControl(state: cameraState, resetID: resetID, projection: projection)
    }
}
#else
private struct RealityStepHostRepresentable: UIViewRepresentable {
    var mesh: StepTriangleMesh
    var options: StepSceneOptions
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var projection: StepCameraProjection
    var resetID: UUID
    var primaryViewRequest: StepPrimaryViewRequest?
    var section: StepSectionPlane
    var sectionColor: PlatformColor
    var measurement: StepMeasurement
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void
    var onMeasureEscape: () -> Void
    @Binding var cameraState: StepSceneCameraState?

    func makeCoordinator() -> RealityStepCameraCoordinator {
        RealityStepCameraCoordinator(cameraState: $cameraState)
    }

    func makeUIView(context: Context) -> RealityStepHostView {
        let view = RealityStepHostView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.installGestures()
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.seedPrimaryViewRequest(primaryViewRequest)
        configure(view)
        return view
    }

    func updateUIView(_ uiView: RealityStepHostView, context: Context) {
        context.coordinator.cameraState = $cameraState
        configure(uiView)
    }

    private func configure(_ view: RealityStepHostView) {
        view.reverseHorizontalRotation = reverseHorizontalRotation
        view.reverseVerticalRotation = reverseVerticalRotation
        view.onMeasurePointPicked = onMeasurePointPicked
        view.onMeasureEscape = onMeasureEscape
        view.apply(
            mesh: mesh,
            options: options,
            isDarkMode: isDarkMode,
            section: section,
            sectionColor: sectionColor,
            measurement: measurement,
            snapModel: snapModel
        )
        view.applyPrimaryViewRequest(primaryViewRequest)
        view.applyCameraControl(state: cameraState, resetID: resetID, projection: projection)
    }
}
#endif

final class RealityStepHostView: ARView {
    var reverseHorizontalRotation = false
    var reverseVerticalRotation = false
    var onMeasurePointPicked: ((StepMeasurePoint) -> Void)?
    var onMeasureEscape: (() -> Void)?

    private let cameraEntity = PerspectiveCamera()
    private let contentAnchor = AnchorEntity(world: .zero)
    private let modelParent = Entity()
    private let decorParent = Entity()

    // Orbit state: spherical coordinates around a movable focus target, which
    // starts at the model's center (the mesh is re-centered on the origin).
    private var target = SIMD3<Float>.zero
    private var azimuth: Float = 0
    private var elevation: Float = 0
    private var distance: Float = 1
    private var largestDimension: Float = 1

    private var installedMesh: StepTriangleMesh?
    private var appliedOptions: StepSceneOptions?
    private var appliedDarkMode: Bool?
    private var appliedSection: StepSectionPlane?
    private var appliedSectionColor: PlatformColor?
    private var modelEntity: ModelEntity?
    private var meshCenter = SIMD3<Float>.zero

    private let sectionParent = Entity()
    private let overlayController = RealityStepOverlayController()
    private var updateSubscription: (any Cancellable)?
    private var snapModel: StepSnapModel?
    private var isMeasuring = false
    private var lastSnapResult: StepSnapResult?
    private var currentSectionClip: SIMD4<Float>?
    private(set) var sectionSnap: StepSectionSnap?
    #if os(macOS)
    private var measureClickLocation: CGPoint?
    private var rightClickCandidates: [StepSnapCandidate] = []
    #endif
    private var capEntity: ModelEntity?
    private var planeEntity: ModelEntity?
    private var planeAxis: StepSectionAxis?
    private var capGeneration = 0
    private var lastCapBucket: Int64 = .min

    var onCameraStateChange: ((StepSceneCameraState?) -> Void)?
    private var lastReportedCameraState: StepSceneCameraState?
    private var appliedResetID: UUID?
    private var currentProjection: StepCameraProjection = .perspective
    /// SCNCamera semantics — half the visible height. Spike-verified identical
    /// to `OrthographicCameraComponent.scale` (vertical, half height), so the
    /// value round-trips between the engines unconverted.
    private var orthographicScale: Double = 1

    /// Shader library for the custom materials; nil falls back to plain PBR
    /// (model renders, sections silently don't clip).
    private lazy var shaderLibrary: MTLLibrary? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? device.makeDefaultLibrary(bundle: .main)
    }()

    func apply(
        mesh: StepTriangleMesh,
        options: StepSceneOptions,
        isDarkMode: Bool,
        section: StepSectionPlane,
        sectionColor: PlatformColor,
        measurement: StepMeasurement,
        snapModel: StepSnapModel?
    ) {
        let meshChanged = installedMesh == nil
            || installedMesh!.vertices.count != mesh.vertices.count
            || installedMesh!.indices.count != mesh.indices.count
        let optionsChanged = options != appliedOptions || isDarkMode != appliedDarkMode
        let sectionChanged = section != appliedSection || sectionColor != appliedSectionColor

        if meshChanged {
            installScene(mesh: mesh)
        }
        if meshChanged || optionsChanged {
            rebuildModel(mesh: mesh, options: options)
            rebuildDecorations(bounds: mesh.bounds, options: options, isDarkMode: isDarkMode)
            appliedOptions = options
            appliedDarkMode = isDarkMode
        }
        if meshChanged || optionsChanged || sectionChanged {
            applySection(section, color: sectionColor, mesh: mesh, force: meshChanged || optionsChanged)
            appliedSection = section
            appliedSectionColor = sectionColor
        }
        applyBackground(isDarkMode: isDarkMode)
        installedMesh = mesh

        self.snapModel = snapModel
        overlayController.snapModel = snapModel
        isMeasuring = measurement.isActive
        overlayController.applyMeasurement(measurement, largestDimension: largestDimension)
        if !measurement.isActive {
            overlayController.clearHighlight()
            lastSnapResult = nil
        }
    }

    private func installScene(mesh: StepTriangleMesh) {
        contentAnchor.children.removeAll()
        scene.anchors.removeAll()
        scene.addAnchor(contentAnchor)
        contentAnchor.addChild(modelParent)
        contentAnchor.addChild(decorParent)
        contentAnchor.addChild(sectionParent)
        overlayController.install(under: contentAnchor)
        // Constant-size overlay scaling runs per frame off the scene clock.
        updateSubscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            guard let self else { return }
            self.overlayController.tick(cameraPosition: self.cameraEntity.position(relativeTo: nil))
        }
        meshCenter = mesh.bounds.center
        capEntity = nil
        planeEntity = nil
        lastCapBucket = .min

        largestDimension = max(mesh.bounds.largestDimension, 1e-4)

        // Simple lighting for now: a key light from the default camera octant
        // plus ARView's default environment. Full lighting parity ports later.
        let light = Entity()
        light.components.set(DirectionalLightComponent(color: .white, intensity: 2_000))
        light.look(at: .zero, from: [1, 1.4, 1.6], relativeTo: nil)
        contentAnchor.addChild(light)

        contentAnchor.addChild(cameraEntity)
        currentProjection = .perspective
        lastReportedCameraState = nil
        frameFactoryCamera()
    }

    /// The same framing as the SceneKit factory: distance multiplier 1.25 on
    /// (0.80, 0.62, 1.15) × largest, field of view 48°.
    private func frameFactoryCamera() {
        let start = SIMD3<Float>(0.80, 0.62, 1.15) * largestDimension * 1.25
        target = .zero
        distance = simd_length(start)
        azimuth = atan2(start.x, start.z)
        elevation = asin(start.y / max(distance, 1e-6))
        cameraEntity.components.remove(OrthographicCameraComponent.self)
        cameraEntity.components.set(PerspectiveCameraComponent(
            near: 0.01,
            far: farPlane,
            fieldOfViewInDegrees: 48
        ))
        currentProjection = .perspective
        updateCameraTransform()
    }

    private var farPlane: Float {
        max(largestDimension * 50, 1_000)
    }

    func applyBackground(isDarkMode: Bool) {
        #if os(macOS)
        environment.background = .color(isDarkMode ? .black : .white)
        #else
        environment.background = .color(isDarkMode ? .black : .white)
        #endif
    }

    // MARK: - Model

    /// Rebuilds the model with the factory's grouping: triangles bucketed by
    /// quantized vertex color (or one neutral bucket), one material per bucket.
    /// Wireframe swaps the solid for a line mesh of the triangle edges —
    /// RealityKit has no `.lines` fill mode.
    private func rebuildModel(mesh: StepTriangleMesh, options: StepSceneOptions) {
        modelParent.children.removeAll()
        let center = mesh.bounds.center

        if options.showsWireframe {
            if let wire = Self.makeWireframeEntity(mesh: mesh, center: center) {
                modelParent.addChild(wire)
            }
            return
        }

        var indicesByMaterial = [StepMaterialKey: [UInt32]]()
        let neutralKey = StepMaterialKey(red: 178, green: 186, blue: 194)
        for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
            let firstIndex = Int(mesh.indices[triangleStart])
            guard firstIndex >= 0 && firstIndex < mesh.vertices.count else { continue }
            let key = options.usesOriginalColors
                ? StepMaterialKey(color: mesh.vertices[firstIndex].color)
                : neutralKey
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart])
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart + 1])
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart + 2])
        }

        let sortedKeys = indicesByMaterial.keys.sorted()
        let positions = mesh.vertices.map { $0.position - center }
        let normals = mesh.vertices.map(\.normal)

        var descriptors = [MeshDescriptor]()
        var materials = [any RealityKit.Material]()
        for (materialIndex, key) in sortedKeys.enumerated() {
            guard let indices = indicesByMaterial[key], !indices.isEmpty else { continue }
            var descriptor = MeshDescriptor(name: "STEP mesh \(materialIndex)")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.primitives = .triangles(indices)
            descriptor.materials = .allFaces(UInt32(materialIndex))
            descriptors.append(descriptor)
            materials.append(makeModelMaterial(color: key.platformColor))
        }

        guard !descriptors.isEmpty,
              let resource = try? MeshResource.generate(from: descriptors) else {
            return
        }

        let entity = ModelEntity(mesh: resource, materials: materials)
        entity.name = "STEP mesh"
        modelParent.addChild(entity)
        modelEntity = entity

        // Precise triangle-accurate collision for raycast snapping. The
        // availability guard is for the SwiftPM dev build (floor macOS 14);
        // the app itself deploys far above it.
        if #available(macOS 15.0, iOS 18.0, *) {
            Task { @MainActor [weak entity] in
                guard let shape = try? await ShapeResource.generateStaticMesh(from: resource) else { return }
                entity?.components.set(CollisionComponent(
                    shapes: [shape],
                    mode: .default,
                    filter: CollisionFilter(group: RealityStepCollision.model, mask: .all)
                ))
            }
        }
    }

    /// A world-space clip vector nothing can exceed: the section is off.
    private static let sectionDisabled = SIMD4<Float>(0, 0, 0, .greatestFiniteMagnitude)

    private func makeModelMaterial(color: PlatformColor) -> any RealityKit.Material {
        // Mirrors the SceneKit material — PBR constants with a slight same-hue
        // emissive lift — as a custom lit material so the section clip can
        // discard in the shader. Double-sided, like the SceneKit install, so a
        // cut-open interior stays visible.
        if let library = shaderLibrary,
           var material = try? CustomMaterial(
               surfaceShader: .init(named: "stairsClipLitSurface", in: library),
               geometryModifier: .init(named: "stairsPassGeometry", in: library),
               lightingModel: .lit
           ) {
            material.baseColor = .init(tint: color)
            material.roughness = .init(floatLiteral: 0.42)
            material.metallic = .init(floatLiteral: 0.0)
            material.emissiveColor = .init(color: color)
            material.faceCulling = .none
            material.custom.value = Self.sectionDisabled
            return material
        }

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.42
        material.metallic = 0.0
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.07
        return material
    }

    /// All unique triangle edges as a line-topology mesh (spike-verified): the
    /// RealityKit stand-in for SceneKit's `.lines` fill mode.
    private static func makeWireframeEntity(mesh: StepTriangleMesh, center: SIMD3<Float>) -> ModelEntity? {
        var seen = Set<UInt64>()
        var lineIndices = [UInt32]()
        func addEdge(_ a: UInt32, _ b: UInt32) {
            let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
            guard seen.insert(key).inserted else { return }
            lineIndices.append(a)
            lineIndices.append(b)
        }
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            let i = mesh.indices[triangle], j = mesh.indices[triangle + 1], k = mesh.indices[triangle + 2]
            addEdge(i, j); addEdge(j, k); addEdge(k, i)
            triangle += 3
        }
        guard !lineIndices.isEmpty else { return nil }

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0)
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        descriptor.vertexCapacity = mesh.vertices.count
        descriptor.indexCapacity = lineIndices.count
        descriptor.indexType = .uint32

        guard let lowLevel = try? LowLevelMesh(descriptor: descriptor) else { return nil }
        let positions = mesh.vertices.map { $0.position - center }
        lowLevel.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
            _ = buffer.bindMemory(to: SIMD3<Float>.self).update(fromContentsOf: positions)
        }
        lowLevel.withUnsafeMutableIndices { buffer in
            _ = buffer.bindMemory(to: UInt32.self).update(fromContentsOf: lineIndices)
        }
        let bounds = mesh.bounds
        lowLevel.parts.append(LowLevelMesh.Part(
            indexOffset: 0,
            indexCount: lineIndices.count,
            topology: .line,
            materialIndex: 0,
            bounds: BoundingBox(
                min: SIMD3<Float>(bounds.minX, bounds.minY, bounds.minZ) - center,
                max: SIMD3<Float>(bounds.maxX, bounds.maxY, bounds.maxZ) - center
            )
        ))

        guard let resource = try? MeshResource(from: lowLevel) else { return nil }
        let entity = ModelEntity(
            mesh: resource,
            materials: [UnlitMaterial(color: PlatformColor.stairsNeutralModel)]
        )
        entity.name = "STEP mesh"
        return entity
    }

    // MARK: - Cross section

    /// Applies the section to the model materials (live, no rebuild) and keeps
    /// the hatched cap and translucent cutting plane in sync.
    private func applySection(
        _ section: StepSectionPlane,
        color: PlatformColor,
        mesh: StepTriangleMesh,
        force: Bool
    ) {
        // 1. The clip, pushed into every model material's custom vector.
        let clip = section.isEnabled
            ? section.clipVector(center: meshCenter)
            : Self.sectionDisabled
        if let entity = modelEntity, var model = entity.model {
            var materials = model.materials
            for index in materials.indices {
                guard var custom = materials[index] as? CustomMaterial else { continue }
                custom.custom.value = clip
                materials[index] = custom
            }
            model.materials = materials
            entity.model = model
        }

        // 2. The cutting plane quad — moved, not rebuilt, while dragging. A
        // rebuild per tick made it blink: a fresh entity can miss a frame while
        // its mesh resource uploads. Only an axis change needs new geometry.
        if section.isEnabled {
            var position = SIMD3<Float>(repeating: 0)
            position[section.axis.index] = section.offset - meshCenter[section.axis.index]
            if let plane = planeEntity, planeAxis == section.axis {
                plane.position = position
                if color != appliedSectionColor {
                    var material = UnlitMaterial(color: color)
                    material.blending = .transparent(opacity: 0.16)
                    plane.model?.materials = [material]
                }
            } else {
                planeEntity?.removeFromParent()
                let plane = Self.makeSectionPlaneEntity(
                    bounds: mesh.bounds,
                    axis: section.axis,
                    center: meshCenter,
                    color: color
                )
                plane.position = position
                sectionParent.addChild(plane)
                planeEntity = plane
                planeAxis = section.axis
            }
        } else {
            planeEntity?.removeFromParent()
            planeEntity = nil
            planeAxis = nil
        }

        currentSectionClip = section.isEnabled ? section.clipVector(center: meshCenter) : nil

        // 3. The hatched cap, rebuilt off the main actor. The outline is built
        // whenever a section is enabled — it feeds measurement snapping even
        // with the cap hidden — and offsets are bucketed (like the SceneKit
        // controller) so a slider drag doesn't queue a build per pixel.
        let buildsOutline = section.isEnabled
        let showsCap = section.isEnabled && section.showsCap
        let bucketScale = Double(max(mesh.bounds.largestDimension, 0.0001)) / 2000
        let bucket = Int64((Double(section.offset) / max(bucketScale, .leastNormalMagnitude)).rounded())
        var capKey: Int64 = .min
        if buildsOutline {
            capKey = bucket ^ Int64(section.axis.index) &* 1_000_003 ^ (section.isFlipped ? 1 << 40 : 0)
            if showsCap { capKey ^= 1 << 41 }
        }

        guard force || capKey != lastCapBucket else {
            if var material = capEntity?.model?.materials.first as? CustomMaterial {
                material.emissiveColor = .init(color: color)
                capEntity?.model?.materials = [material]
            }
            return
        }
        lastCapBucket = capKey

        capGeneration += 1
        let token = capGeneration
        guard buildsOutline else {
            capEntity?.removeFromParent()
            capEntity = nil
            sectionSnap = nil
            return
        }
        // The outgoing cap stays visible until its replacement arrives.
        // Removing it up front left a hole for the async build's duration —
        // which read as flicker at every step of a drag.

        let plane = section
        let largest = mesh.bounds.largestDimension
        Task { @MainActor [weak self] in
            let capMesh = await Task.detached(priority: .userInitiated) {
                StepSectionCapBuilder.build(mesh: mesh, plane: plane)
            }.value
            guard let self, token == self.capGeneration else { return }
            guard let capMesh, !capMesh.isEmpty else {
                self.sectionSnap = nil
                self.capEntity?.removeFromParent()
                self.capEntity = nil
                return
            }
            let snap = StepSectionSnap(loops: capMesh.loops, center: self.meshCenter, largestDimension: largest)
            self.sectionSnap = snap.isEmpty ? nil : snap
            guard showsCap, let entity = self.makeCapEntity(capMesh) else {
                self.capEntity?.removeFromParent()
                self.capEntity = nil
                return
            }
            self.applyHatchMaterial(to: entity, color: color)
            self.sectionParent.addChild(entity)
            self.capEntity?.removeFromParent()
            self.capEntity = entity
        }
    }

    private func makeCapEntity(_ capMesh: StepSectionCapMesh) -> ModelEntity? {
        var descriptor = MeshDescriptor(name: "Section cap")
        descriptor.positions = MeshBuffer(capMesh.positions.map { $0 - meshCenter })
        descriptor.normals = MeshBuffer(capMesh.positions.map { _ in capMesh.normal })
        descriptor.primitives = .triangles(capMesh.indices)
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: resource, materials: [UnlitMaterial(color: .gray)])
        entity.name = "Section cap"
        if #available(macOS 15.0, iOS 18.0, *) {
            Task { @MainActor [weak entity] in
                guard let shape = try? await ShapeResource.generateStaticMesh(from: resource) else { return }
                entity?.components.set(CollisionComponent(
                    shapes: [shape],
                    mode: .default,
                    filter: CollisionFilter(group: RealityStepCollision.sectionCap, mask: .all)
                ))
            }
        }
        return entity
    }

    /// The spike-verified screen-space hatch: fill colour in the material's
    /// emissive slot, viewport size and spacing in the custom vector.
    private func applyHatchMaterial(to entity: ModelEntity, color: PlatformColor) {
        guard let library = shaderLibrary,
              var material = try? CustomMaterial(
                  surfaceShader: .init(named: "stairsHatchSurface", in: library),
                  geometryModifier: .init(named: "stairsPassGeometry", in: library),
                  lightingModel: .unlit
              ) else {
            entity.model?.materials = [UnlitMaterial(color: color)]
            return
        }
        material.emissiveColor = .init(color: color)
        material.faceCulling = .none
        material.custom.value = hatchCustomVector
        entity.model?.materials = [material]
    }

    /// (viewW, viewH, spacing, lineWidth) in device pixels — no resolution
    /// uniform exists in RealityKit's shader API, so the view supplies it and
    /// refreshes it on layout.
    private var hatchCustomVector: SIMD4<Float> {
        #if os(macOS)
        let scale = Float(window?.backingScaleFactor ?? 2)
        #else
        let scale = Float(contentScaleFactor)
        #endif
        return SIMD4<Float>(
            Float(bounds.width) * scale,
            Float(bounds.height) * scale,
            StepSectionShader.hatchSpacingPixels,
            StepSectionShader.hatchLineWidthPixels
        )
    }

    private func refreshHatchViewport() {
        guard let entity = capEntity,
              var material = entity.model?.materials.first as? CustomMaterial else { return }
        material.custom.value = hatchCustomVector
        entity.model?.materials = [material]
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        refreshHatchViewport()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        refreshHatchViewport()
    }
    #endif

    private static func makeSectionPlaneEntity(
        bounds: StepBounds,
        axis: StepSectionAxis,
        center: SIMD3<Float>,
        color: PlatformColor
    ) -> ModelEntity {
        // Same geometry as the SceneKit controller: the plane's quad spans the
        // model's in-plane extent plus an 8% margin, in world (centered) space.
        // Built in the plane through the model's centre; the caller positions it
        // along the axis, so dragging is a translation rather than a rebuild.
        let (uAxis, vAxis): (StepSectionAxis, StepSectionAxis) = {
            switch axis {
            case .x: (.y, .z)
            case .y: (.x, .z)
            case .z: (.x, .y)
            }
        }()
        let expand: Float = 0.08
        let uMin = bounds.minValue(axis: uAxis), uMax = bounds.maxValue(axis: uAxis)
        let vMin = bounds.minValue(axis: vAxis), vMax = bounds.maxValue(axis: vAxis)
        let uPad = (uMax - uMin) * expand, vPad = (vMax - vMin) * expand

        func corner(_ u: Float, _ v: Float) -> SIMD3<Float> {
            var p = SIMD3<Float>(repeating: 0)
            p[axis.index] = center[axis.index]
            p[uAxis.index] = u
            p[vAxis.index] = v
            return p - center
        }
        let corners = [
            corner(uMin - uPad, vMin - vPad),
            corner(uMax + uPad, vMin - vPad),
            corner(uMax + uPad, vMax + vPad),
            corner(uMin - uPad, vMax + vPad),
        ]

        var descriptor = MeshDescriptor(name: "Section plane")
        descriptor.positions = MeshBuffer(corners)
        var normal = SIMD3<Float>(repeating: 0)
        normal[axis.index] = 1
        descriptor.normals = MeshBuffer([normal, normal, normal, normal])
        // Both windings, so the quad is visible from either side without
        // relying on material face-culling settings.
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0])

        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: 0.16)
        let entity = ModelEntity(
            mesh: (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 0.001),
            materials: [material]
        )
        entity.name = "Section plane"
        return entity
    }

    // MARK: - Decorations (grid, axes, floor) — world space, like the factory

    private func rebuildDecorations(bounds: StepBounds, options: StepSceneOptions, isDarkMode: Bool) {
        decorParent.children.removeAll()
        if options.showsGrid {
            if let grid = Self.makeGridEntity(bounds: bounds) {
                decorParent.addChild(grid)
            }
        }
        if options.showsAxes {
            decorParent.addChild(Self.makeAxesEntity(bounds: bounds))
        }
        if options.showsFloor {
            decorParent.addChild(Self.makeFloorEntity(bounds: bounds, isDarkMode: isDarkMode))
        }
    }

    private static func floorMetrics(for bounds: StepBounds) -> (largest: Float, halfExtent: Float, y: Float) {
        let largest = max(bounds.largestDimension, 10)
        return (largest, largest * 0.65, -max(bounds.height, 0.1) / 2)
    }

    private static func niceGridStep(for extent: Float) -> Float {
        let roughStep = max(extent / 12, 0.1)
        let exponent = floor(log10(roughStep))
        let base = pow(10, exponent)
        let fraction = roughStep / base
        if fraction < 2 { return base }
        if fraction < 5 { return base * 2 }
        return base * 5
    }

    private static func makeGridEntity(bounds: StepBounds) -> ModelEntity? {
        let metrics = floorMetrics(for: bounds)
        let gridStep = niceGridStep(for: metrics.largest)
        let lineCount = min(max(Int(ceil(metrics.halfExtent / gridStep)), 2), 80)

        var vertices = [SIMD3<Float>]()
        var indices = [UInt32]()
        for line in -lineCount...lineCount {
            let offset = Float(line) * gridStep
            let base = UInt32(vertices.count)
            vertices.append([-metrics.halfExtent, metrics.y, offset])
            vertices.append([metrics.halfExtent, metrics.y, offset])
            vertices.append([offset, metrics.y, -metrics.halfExtent])
            vertices.append([offset, metrics.y, metrics.halfExtent])
            indices.append(contentsOf: [base, base + 1, base + 2, base + 3])
        }

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0)
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        descriptor.vertexCapacity = vertices.count
        descriptor.indexCapacity = indices.count
        descriptor.indexType = .uint32
        guard let lowLevel = try? LowLevelMesh(descriptor: descriptor) else { return nil }
        lowLevel.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
            _ = buffer.bindMemory(to: SIMD3<Float>.self).update(fromContentsOf: vertices)
        }
        lowLevel.withUnsafeMutableIndices { buffer in
            _ = buffer.bindMemory(to: UInt32.self).update(fromContentsOf: indices)
        }
        lowLevel.parts.append(LowLevelMesh.Part(
            indexOffset: 0,
            indexCount: indices.count,
            topology: .line,
            materialIndex: 0,
            bounds: BoundingBox(
                min: [-metrics.halfExtent, metrics.y - 1, -metrics.halfExtent],
                max: [metrics.halfExtent, metrics.y + 1, metrics.halfExtent]
            )
        ))
        guard let resource = try? MeshResource(from: lowLevel) else { return nil }

        var material = UnlitMaterial(color: PlatformColor.stairsGrid)
        material.blending = .transparent(opacity: 0.28)
        let entity = ModelEntity(mesh: resource, materials: [material])
        entity.name = "Grid"
        return entity
    }

    private static func makeAxesEntity(bounds: StepBounds) -> Entity {
        let length = max(bounds.largestDimension * 0.28, 5)
        let radius = max(length * 0.008, 0.025)
        let axes: [(direction: SIMD3<Float>, color: PlatformColor)] = [
            ([1, 0, 0], PlatformColor(red: 0.95, green: 0.20, blue: 0.16, alpha: 1)),
            ([0, 1, 0], PlatformColor(red: 0.20, green: 0.78, blue: 0.30, alpha: 1)),
            ([0, 0, 1], PlatformColor(red: 0.22, green: 0.48, blue: 1.00, alpha: 1)),
        ]

        let parent = Entity()
        parent.name = "Axes"
        for axis in axes {
            let box = MeshResource.generateBox(size: [radius * 2, length, radius * 2])
            var material = UnlitMaterial(color: axis.color)
            material.blending = .opaque
            let entity = ModelEntity(mesh: box, materials: [material])
            // The box runs along +Y; rotate onto the axis and center it on the
            // positive half, matching the factory's cylinders from the origin.
            entity.position = axis.direction * (length / 2)
            if axis.direction.x == 1 {
                entity.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
            } else if axis.direction.z == 1 {
                entity.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            }
            parent.addChild(entity)
        }
        return parent
    }

    private static func makeFloorEntity(bounds: StepBounds, isDarkMode: Bool) -> ModelEntity {
        let metrics = floorMetrics(for: bounds)
        let plane = MeshResource.generatePlane(width: metrics.halfExtent * 2, depth: metrics.halfExtent * 2)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: isDarkMode ? .white : .black)
        material.roughness = 0.95
        material.metallic = 0.0
        material.blending = .transparent(opacity: .init(floatLiteral: isDarkMode ? 0.045 : 0.025))
        let entity = ModelEntity(mesh: plane, materials: [material])
        entity.name = "Shadow floor"
        entity.position = [0, metrics.y - max(metrics.largest * 0.0008, 0.001), 0]
        return entity
    }

    // MARK: - Camera

    private func updateCameraTransform() {
        elevation = max(-.pi / 2 + 0.002, min(.pi / 2 - 0.002, elevation))
        let offset = SIMD3<Float>(
            distance * sin(azimuth) * cos(elevation),
            distance * sin(elevation),
            distance * cos(azimuth) * cos(elevation)
        )
        // The orbit frame's own up — d(position)/d(elevation) — instead of a
        // fixed world up, so the pole views (top and bottom, keys 3/4) are
        // well-defined instead of degenerate.
        let up = SIMD3<Float>(
            -sin(azimuth) * sin(elevation),
            cos(elevation),
            -cos(azimuth) * sin(elevation)
        )
        cameraEntity.look(at: target, from: target + offset, upVector: up, relativeTo: nil)
    }

    /// Jumps to a named viewpoint — axis or axonometric — keeping the current
    /// distance and focus target. Azimuth 0 at the poles orients the top view
    /// with +X right and +Z toward the viewer's bottom edge, matching the
    /// SceneKit canvas.
    func applyPrimaryView(_ primary: StepPrimaryView) {
        let direction = primary.direction
        if abs(direction.y) > 0.999 {
            azimuth = 0
            elevation = direction.y > 0 ? .pi / 2 : -.pi / 2
        } else {
            azimuth = atan2(direction.x, direction.z)
            elevation = asin(max(-1, min(1, direction.y)))
        }
        updateCameraTransform()
        reportCameraState()
    }

    /// Menu-driven viewpoint jumps. Only a *change* of request token fires, so
    /// a view recreated by SwiftUI never replays a stale request.
    private var appliedPrimaryViewRequestID: UUID?

    func seedPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
        appliedPrimaryViewRequestID = request?.id
    }

    func applyPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
        guard let request, request.id != appliedPrimaryViewRequestID else { return }
        appliedPrimaryViewRequestID = request.id
        // Deferred a runloop: requests arrive inside a SwiftUI update pass, and
        // the jump reports camera state — a binding write, illegal mid-update.
        DispatchQueue.main.async { [weak self] in
            self?.applyPrimaryView(request.view)
        }
    }

    private func orbit(deltaX: Float, deltaY: Float) {
        azimuth -= (reverseHorizontalRotation ? -deltaX : deltaX) * 0.008
        elevation += (reverseVerticalRotation ? -deltaY : deltaY) * 0.008
        updateCameraTransform()
        reportCameraState()
    }

    private func pan(deltaX: Float, deltaY: Float) {
        // The factory scale: screen points to world at the focus distance.
        let scale = distance * 0.0015
        let transform = cameraEntity.transform.matrix
        let right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        target += right * (-deltaX * scale) + up * (deltaY * scale)
        updateCameraTransform()
        reportCameraState()
    }

    private func zoom(scale: Float, towards viewPoint: CGPoint?) {
        guard scale.isFinite, scale > 0 else { return }
        if currentProjection == .orthographic {
            // Orthographic zoom is a scale change, not a dolly — the SceneKit
            // canvas clamps to the same absolute range.
            let anchorBefore = viewPoint.flatMap { focusPlanePoint(at: $0) }
            let newScale = orthographicScale / Double(scale)
            guard newScale >= 0.02, newScale <= 500_000 else { return }
            orthographicScale = newScale
            refreshOrthographicComponent()
            if let anchorBefore, let viewPoint, let anchorAfter = focusPlanePoint(at: viewPoint) {
                let shift = anchorBefore - anchorAfter
                if shift.x.isFinite, shift.y.isFinite, shift.z.isFinite {
                    target += shift
                    updateCameraTransform()
                }
            }
            reportCameraState()
            return
        }
        let anchorBefore = viewPoint.flatMap { focusPlanePoint(at: $0) }
        distance = min(max(distance / scale, largestDimension * 0.02), largestDimension * 40)
        updateCameraTransform()
        // Anchored zoom: keep the world point under the cursor stationary by
        // shifting the focus target by the anchor's apparent drift.
        if let anchorBefore, let viewPoint, let anchorAfter = focusPlanePoint(at: viewPoint) {
            target += anchorBefore - anchorAfter
            updateCameraTransform()
        }
        reportCameraState()
    }

    /// The world point where the cursor ray crosses the plane through the focus
    /// target perpendicular to the camera's forward direction.
    private func focusPlanePoint(at viewPoint: CGPoint) -> SIMD3<Float>? {
        guard let pointRay = ray(through: viewPoint) else { return nil }
        let transform = cameraEntity.transform.matrix
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let denominator = simd_dot(pointRay.direction, forward)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = simd_dot(target - pointRay.origin, forward) / denominator
        return pointRay.origin + pointRay.direction * t
    }

    // MARK: - Camera state (shared with the SceneKit canvas)

    /// One entry point for everything the document view knows about the camera:
    /// the persisted/shared state, the Home-button reset token, and the menu's
    /// projection choice. Ordering mirrors the SceneKit canvas — restore the
    /// state first, then let the menu projection win if it differs.
    func applyCameraControl(state: StepSceneCameraState?, resetID: UUID, projection: StepCameraProjection) {
        if appliedResetID == nil {
            appliedResetID = resetID
        } else if appliedResetID != resetID {
            appliedResetID = resetID
            frameFactoryCamera()
            lastReportedCameraState = nil
        }
        applyCameraState(state)
        applyProjection(projection, orthographicScale: nil)
        if lastReportedCameraState == nil || lastReportedCameraState?.projection != currentProjection {
            // Publish the initial framing (and projection switches, which also
            // happen here) so the scale bar and persistence always have a
            // current state. Deferred one runloop: this path runs inside a
            // SwiftUI update pass, where writing the binding is not allowed.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.lastReportedCameraState == nil
                    || self.lastReportedCameraState?.projection != self.currentProjection {
                    self.reportCameraState()
                }
            }
        }
    }

    /// Restores a camera state produced by either engine. The transform is
    /// decomposed into the spherical orbit frame: the focus target lands on the
    /// forward ray at the state's distance to the world-origin plane — the same
    /// focus convention the SceneKit canvas uses. Roll (which the orbit UI
    /// cannot produce) is dropped; the analytic up vector regenerates it.
    private func applyCameraState(_ state: StepSceneCameraState?) {
        guard let state, state.isValid, state != lastReportedCameraState else { return }
        let t = state.transform
        let position = SIMD3<Float>(t[12], t[13], t[14])
        let forwardRaw = -SIMD3<Float>(t[8], t[9], t[10])
        let forwardLength = simd_length(forwardRaw)
        guard forwardLength > 1e-6 else { return }
        let forward = forwardRaw / forwardLength
        let toOriginPlane = simd_dot(-position, forward)
        let focus = toOriginPlane.isFinite && toOriginPlane > 0 ? toOriginPlane : simd_length(position)
        distance = max(focus, 1e-4)
        target = position + forward * distance
        let offset = position - target
        elevation = asin(max(-1, min(1, offset.y / distance)))
        azimuth = atan2(offset.x, offset.z)
        updateCameraTransform()
        applyProjection(state.projection, orthographicScale: state.orthographicScale)
        lastReportedCameraState = state
    }

    /// Switches the camera component. Entering orthographic seeds the scale so
    /// the visible height matches what the perspective camera showed, exactly
    /// like the SceneKit canvas.
    private func applyProjection(_ projection: StepCameraProjection, orthographicScale incoming: Double?) {
        let wantsOrthographic = projection == .orthographic
        if wantsOrthographic {
            if currentProjection != .orthographic {
                orthographicScale = incoming ?? visibleHalfHeight()
            } else if let incoming, incoming.isFinite, incoming > 0 {
                orthographicScale = incoming
            }
        }
        guard currentProjection != projection else {
            if wantsOrthographic {
                refreshOrthographicComponent()
            }
            return
        }
        currentProjection = projection
        if wantsOrthographic {
            cameraEntity.components.remove(PerspectiveCameraComponent.self)
            refreshOrthographicComponent()
        } else {
            cameraEntity.components.remove(OrthographicCameraComponent.self)
            cameraEntity.components.set(PerspectiveCameraComponent(
                near: 0.01,
                far: farPlane,
                fieldOfViewInDegrees: 48
            ))
        }
    }

    private func refreshOrthographicComponent() {
        var camera = cameraEntity.components[OrthographicCameraComponent.self] ?? {
            var fresh = OrthographicCameraComponent()
            fresh.near = 0.01
            fresh.far = farPlane
            return fresh
        }()
        let scale = Float(orthographicScale)
        guard camera.scale != scale || !cameraEntity.components.has(OrthographicCameraComponent.self) else { return }
        camera.scale = scale
        cameraEntity.components.set(camera)
    }

    /// Half the world height visible at the focus distance under the 48° FOV —
    /// the SceneKit canvas's `visibleHeight / 2`, used to seed the orthographic
    /// scale so the projection toggle keeps the framing.
    private func visibleHalfHeight() -> Double {
        let toOriginPlane = simd_dot(-cameraEntity.position(relativeTo: nil), cameraForward)
        let focus = Double(toOriginPlane.isFinite && toOriginPlane > 0
            ? toOriginPlane
            : simd_length(cameraEntity.position(relativeTo: nil)))
        return max(max(focus, 1) * tan(48.0 * .pi / 180 / 2), 0.0001)
    }

    private var cameraForward: SIMD3<Float> {
        let transform = cameraEntity.transformMatrix(relativeTo: nil)
        return -simd_normalize(SIMD3<Float>(
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z
        ))
    }

    private func reportCameraState() {
        let m = cameraEntity.transformMatrix(relativeTo: nil)
        let state = StepSceneCameraState(
            transform: [
                m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
            ],
            projection: currentProjection,
            orthographicScale: currentProjection == .orthographic ? orthographicScale : nil
        )
        lastReportedCameraState = state
        onCameraStateChange?(state)
    }

    // MARK: - Measurement input

    private func updateMeasurementHighlight(at location: CGPoint) {
        guard isMeasuring, let snapModel else {
            overlayController.clearHighlight()
            lastSnapResult = nil
            return
        }
        let result = StepSnapResolver.resolve(
            view: self,
            snapModel: snapModel,
            viewPoint: location,
            sectionSnap: sectionSnap,
            sectionClip: currentSectionClip,
            previous: lastSnapResult
        )
        lastSnapResult = result
        overlayController.applyHighlight(result, largestDimension: largestDimension, sectionClip: currentSectionClip)
    }

    private func commitMeasurePoint(at location: CGPoint) {
        guard let snapModel,
              let result = StepSnapResolver.resolve(
                view: self,
                snapModel: snapModel,
                viewPoint: location,
                sectionSnap: sectionSnap,
                sectionClip: currentSectionClip,
                previous: lastSnapResult
              ) else { return }
        lastSnapResult = result
        onMeasurePointPicked?(StepMeasurePoint(
            position: result.point,
            kind: result.kind,
            plane: result.plane,
            line: result.line,
            edge: result.edge
        ))
    }

    // MARK: - Input

    #if os(macOS)
    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self) // bare-key view shortcuts (1–6, i/d/t)
    }

    override func keyDown(with event: NSEvent) {
        if isMeasuring, event.keyCode == 53 { // Escape clears the measurement
            onMeasureEscape?()
            return
        }
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let characters = event.charactersIgnoringModifiers,
           let primary = StepPrimaryView(key: characters) {
            applyPrimaryView(primary)
            return
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateMeasurementHighlight(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        overlayController.clearHighlight()
        lastSnapResult = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isMeasuring {
            measureClickLocation = convert(event.locationInWindow, from: nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isMeasuring, let down = measureClickLocation {
            let location = convert(event.locationInWindow, from: nil)
            // A click (barely moved) commits a measurement point; a drag orbited.
            if hypot(location.x - down.x, location.y - down.y) <= 4 {
                commitMeasurePoint(at: location)
            }
        }
        measureClickLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        orbit(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
        if let down = measureClickLocation {
            let location = convert(event.locationInWindow, from: nil)
            if hypot(location.x - down.x, location.y - down.y) > 4 {
                measureClickLocation = nil // became a drag, not a click
            }
        }
    }

    /// Right-click while measuring lists every snap target under the cursor,
    /// nearest first — same behaviour as the SceneKit canvas, via the shared
    /// resolver.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isMeasuring, let snapModel else {
            return super.menu(for: event)
        }
        let location = convert(event.locationInWindow, from: nil)
        let candidates = StepSnapResolver.candidates(
            view: self,
            snapModel: snapModel,
            viewPoint: location,
            boundsCenter: meshCenter,
            sectionSnap: sectionSnap,
            sectionClip: currentSectionClip
        )
        guard !candidates.isEmpty else { return nil }
        rightClickCandidates = candidates

        let menu = NSMenu()
        let header = NSMenuItem(title: "Measure to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for (index, candidate) in candidates.enumerated() {
            let item = NSMenuItem(title: candidate.label, action: #selector(selectCandidate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectCandidate(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < rightClickCandidates.count else { return }
        onMeasurePointPicked?(rightClickCandidates[sender.tag].measurePoint)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            pan(deltaX: Float(event.scrollingDeltaX), deltaY: Float(event.scrollingDeltaY))
        } else {
            zoom(scale: 1 + Float(event.scrollingDeltaY) * 0.01, towards: location)
        }
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        zoom(scale: 1 + Float(event.magnification), towards: location)
    }
    #else
    private var lastPanLocation: CGPoint?
    private var lastTwoFingerLocation: CGPoint?
    private var lastPinchScale: CGFloat = 1
    private var lastTrackpadPinchScale: CGFloat = 1

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder() // hardware-keyboard view keys (1–6, i/d/t)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = StepPrimaryView.allKeys.map { key in
            UIKeyCommand(
                input: key,
                modifierFlags: [],
                action: #selector(handlePrimaryViewKey(_:))
            )
        }
        commands.append(UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(handleEscapeKey)
        ))
        return commands
    }

    @objc private func handleEscapeKey() {
        guard isMeasuring else { return }
        onMeasureEscape?()
    }

    @objc private func handlePrimaryViewKey(_ command: UIKeyCommand) {
        guard let input = command.input, let primary = StepPrimaryView(key: input) else { return }
        applyPrimaryView(primary)
    }

    func installGestures() {
        let orbitPan = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbitPan.maximumNumberOfTouches = 1
        addGestureRecognizer(orbitPan)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerPan)

        // Trackpad: two-finger scrolling pans, pinching zooms, matching macOS.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.allowedScrollTypesMask = .continuous
        scrollPan.maximumNumberOfTouches = 0
        addGestureRecognizer(scrollPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // Hover previews the snap (pointer or Pencil); a tap commits it.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        hover.requiresExclusiveTouchType = false
        hover.cancelsTouchesInView = false
        addGestureRecognizer(hover)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            updateMeasurementHighlight(at: recognizer.location(in: self))
        default:
            overlayController.clearHighlight()
            lastSnapResult = nil
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isMeasuring, recognizer.state == .ended else { return }
        commitMeasurePoint(at: recognizer.location(in: self))
    }

    @objc private func handleOrbitPan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        defer { lastPanLocation = recognizer.state == .changed ? location : nil }
        guard recognizer.state == .changed, let previous = lastPanLocation else { return }
        orbit(
            deltaX: Float(location.x - previous.x),
            deltaY: Float(location.y - previous.y)
        )
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        defer { lastTwoFingerLocation = recognizer.state == .changed ? location : nil }
        guard recognizer.state == .changed, let previous = lastTwoFingerLocation else { return }
        pan(
            deltaX: Float(location.x - previous.x),
            deltaY: Float(location.y - previous.y)
        )
    }

    @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        pan(deltaX: Float(translation.x), deltaY: Float(translation.y))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let isTrackpad = recognizer.numberOfTouches == 0
        switch recognizer.state {
        case .began:
            if isTrackpad { lastTrackpadPinchScale = recognizer.scale } else { lastPinchScale = recognizer.scale }
        case .changed:
            let scale = max(recognizer.scale, 0.0001)
            let previous = isTrackpad ? lastTrackpadPinchScale : lastPinchScale
            zoom(scale: Float(scale / max(previous, 0.0001)), towards: recognizer.location(in: self))
            if isTrackpad { lastTrackpadPinchScale = scale } else { lastPinchScale = scale }
        default:
            lastPinchScale = 1
            lastTrackpadPinchScale = 1
        }
    }
    #endif
}

/// RealityKit's side of the ``StepSnapScene`` seam — the same three operations
/// the SceneKit view provides, so the snap resolver runs against either engine.
extension RealityStepHostView: StepSnapScene {
    public func snapScreenPoint(for worldPoint: SIMD3<Float>) -> SIMD2<Float>? {
        guard let projected = project(worldPoint) else {
            return nil
        }
        return SIMD2<Float>(Float(projected.x), Float(projected.y))
    }

    public func snapSurfaceHits(at viewPoint: CGPoint) -> [StepSnapSurfaceHit] {
        guard let pointRay = ray(through: viewPoint) else {
            return []
        }
        // Precise, triangle-accurate crossings against the model's static-mesh
        // collision. The section cap joins as a second group when it ports.
        return scene.raycast(
            origin: pointRay.origin,
            direction: pointRay.direction,
            length: max(largestDimension * 100, 1_000),
            query: .all,
            mask: RealityStepCollision.model,
            relativeTo: nil
        )
        .sorted { $0.distance < $1.distance }
        .map { StepSnapSurfaceHit(surface: .model, worldPoint: $0.position) }
    }

    public var snapCameraPosition: SIMD3<Float>? {
        cameraEntity.position(relativeTo: nil)
    }
}
