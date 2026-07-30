import SceneKit
import StairsCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
private typealias SceneKitScalar = CGFloat
#else
private typealias SceneKitScalar = Float
#endif

struct StepSceneCanvas: View {
    var presentation: StepScenePresentation
    var projection: StepCameraProjection
    var isDarkMode: Bool
    var reverseHorizontalRotation = false
    var reverseVerticalRotation = false
    var interactionInsets = EdgeInsets()
    var primaryViewRequest: StepPrimaryViewRequest?
    var section = StepSectionPlane()
    var sectionSourceMesh: StepTriangleMesh?
    var sectionColor: PlatformColor = .systemBlue
    var boundsCenter = SIMD3<Float>(repeating: 0)
    var modelID = UUID()
    var isPickingSectionPoint = false
    var onSectionOffsetPicked: (Float) -> Void = { _ in }
    var measurement = StepMeasurement()
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void = { _ in }
    var onMeasureEscape: () -> Void = {}
    @Binding var cameraState: StepSceneCameraState?

    var body: some View {
        StepSceneHostView(
            presentation: presentation,
            projection: projection,
            isDarkMode: isDarkMode,
            reverseHorizontalRotation: reverseHorizontalRotation,
            reverseVerticalRotation: reverseVerticalRotation,
            interactionInsets: interactionInsets,
            primaryViewRequest: primaryViewRequest,
            section: section,
            sectionSourceMesh: sectionSourceMesh,
            sectionColor: sectionColor,
            boundsCenter: boundsCenter,
            modelID: modelID,
            isPickingSectionPoint: isPickingSectionPoint,
            onSectionOffsetPicked: onSectionOffsetPicked,
            measurement: measurement,
            snapModel: snapModel,
            onMeasurePointPicked: onMeasurePointPicked,
            onMeasureEscape: onMeasureEscape,
            cameraState: $cameraState
        )
        .background(isDarkMode ? Color.black : Color.white)
    }
}

/// Shared, main-actor controller that keeps the cross-section's decorations in
/// sync with the plane: a hatched solid cap over the cut face (rebuilt off the
/// main actor, debounced by a generation token) and a translucent cutting-plane
/// quad. Both are parented under the centered model node so they share the mesh's
/// coordinate space, and both carry the pick-exclusion category so they never
/// intercept measurement or section-point hit tests.
@MainActor
final class StepSectionCapController {
    static let capNodeName = "Section cap"
    static let planeNodeName = "Section plane"

    /// The cap carries its own category rather than the measurement-overlay one:
    /// measurement snapping *does* hit-test it (so the cut outline is selectable),
    /// while section-point picking excludes it to read the surface behind.
    static let capCategoryBitMask = 1 << 21

    /// The cutting plane is its own category too: it must never intercept a
    /// measurement or section-point ray, but dragging it needs to hit-test it.
    static let planeCategoryBitMask = 1 << 22

    /// Everything that must stay invisible to measurement/section-point rays.
    static let nonSnappableCategoryBitMask =
        StepMeasurementController.overlayCategoryBitMask | planeCategoryBitMask

    /// The current cut outline's corners and edges, in world space, for snapping
    /// measurements to the cross section. Present whenever a section is enabled
    /// and its outline could be computed — including when the cap isn't drawn.
    private(set) var sectionSnap: StepSectionSnap?

    private var generation = 0
    private var lastCapKey: CapKey?
    private var lastPlaneKey: PlaneKey?
    private weak var currentRootNode: SCNNode?

    private struct CapKey: Equatable {
        var modelID: UUID
        var enabled: Bool
        var showsCap: Bool
        var axis: StepSectionAxis
        var flipped: Bool
        var offsetBucket: Int64
    }

    private struct PlaneKey: Equatable {
        var modelID: UUID
        var enabled: Bool
        var axis: StepSectionAxis
        var offsetBucket: Int64
    }

    func update(
        modelID: UUID,
        mesh: StepTriangleMesh?,
        section: StepSectionPlane,
        rootNode: SCNNode?,
        color: PlatformColor,
        center: SIMD3<Float>
    ) {
        let rootChanged = rootNode !== currentRootNode
        currentRootNode = rootNode
        let bucketScale = Double(max(mesh?.bounds.largestDimension ?? 1, 0.0001)) / 2000
        let offsetBucket = Int64((Double(section.offset) / max(bucketScale, .leastNormalMagnitude)).rounded())

        updateCap(modelID: modelID, mesh: mesh, section: section, rootNode: rootNode, rootChanged: rootChanged, offsetBucket: offsetBucket, color: color, center: center)
        updatePlane(modelID: modelID, mesh: mesh, section: section, rootNode: rootNode, rootChanged: rootChanged, offsetBucket: offsetBucket, color: color)
        // Colour changes don't rebuild geometry — retint whatever's already there.
        applyColor(color, in: rootNode)
    }

    // MARK: - Cap

    private func updateCap(
        modelID: UUID,
        mesh: StepTriangleMesh?,
        section: StepSectionPlane,
        rootNode: SCNNode?,
        rootChanged: Bool,
        offsetBucket: Int64,
        color: PlatformColor,
        center: SIMD3<Float>
    ) {
        // The outline is computed whenever a section is enabled — it feeds
        // measurement snapping even when the solid cap itself isn't drawn.
        let shouldBuild = section.isEnabled && mesh != nil
        let showsCap = section.showsCap
        let key = CapKey(
            modelID: modelID,
            enabled: section.isEnabled,
            showsCap: showsCap,
            axis: section.axis,
            flipped: section.isFlipped,
            offsetBucket: offsetBucket
        )

        if key == lastCapKey, !rootChanged, capNode(in: rootNode) != nil || !(shouldBuild && showsCap) {
            return
        }
        lastCapKey = key

        generation += 1
        let token = generation
        removeCap(from: rootNode)

        guard shouldBuild, let mesh else {
            sectionSnap = nil
            return
        }

        let plane = section
        let largest = mesh.bounds.largestDimension
        Task.detached(priority: .userInitiated) {
            let capMesh = StepSectionCapBuilder.build(mesh: mesh, plane: plane)
            await MainActor.run {
                self.installCap(
                    capMesh,
                    token: token,
                    color: color,
                    showsCap: showsCap,
                    center: center,
                    largestDimension: largest
                )
            }
        }
    }

    private func installCap(
        _ capMesh: StepSectionCapMesh?,
        token: Int,
        color: PlatformColor,
        showsCap: Bool,
        center: SIMD3<Float>,
        largestDimension: Float
    ) {
        guard token == generation, let rootNode = currentRootNode else {
            return
        }
        removeCap(from: rootNode)
        guard let capMesh, !capMesh.isEmpty else {
            sectionSnap = nil
            return
        }
        let snap = StepSectionSnap(loops: capMesh.loops, center: center, largestDimension: largestDimension)
        sectionSnap = snap.isEmpty ? nil : snap
        guard showsCap else {
            return
        }
        rootNode.addChildNode(Self.makeCapNode(from: capMesh, color: color))
    }

    private func capNode(in rootNode: SCNNode?) -> SCNNode? {
        rootNode?.childNodes.first { $0.name == Self.capNodeName }
    }

    private func removeCap(from rootNode: SCNNode?) {
        capNode(in: rootNode)?.removeFromParentNode()
    }

    private static func makeCapNode(from capMesh: StepSectionCapMesh, color: PlatformColor) -> SCNNode {
        let positions = capMesh.positions.map { SCNVector3($0) }
        let normals = capMesh.positions.map { _ in SCNVector3(capMesh.normal) }
        let indexData = capMesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: capMesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals)
            ],
            elements: [element]
        )
        geometry.firstMaterial = StepSectionShader.makeCapMaterial(color: color)

        let node = SCNNode(geometry: geometry)
        node.name = capNodeName
        node.categoryBitMask = capCategoryBitMask
        node.castsShadow = false
        return node
    }

    // MARK: - Cutting plane

    private func updatePlane(
        modelID: UUID,
        mesh: StepTriangleMesh?,
        section: StepSectionPlane,
        rootNode: SCNNode?,
        rootChanged: Bool,
        offsetBucket: Int64,
        color: PlatformColor
    ) {
        let key = PlaneKey(modelID: modelID, enabled: section.isEnabled, axis: section.axis, offsetBucket: offsetBucket)
        let shouldShow = section.isEnabled && mesh != nil
        if key == lastPlaneKey, !rootChanged, planeNode(in: rootNode) != nil || !shouldShow {
            return
        }
        lastPlaneKey = key

        removePlane(from: rootNode)
        guard shouldShow, let mesh, let rootNode else {
            return
        }
        rootNode.addChildNode(Self.makeSectionPlaneNode(bounds: mesh.bounds, section: section, color: color))
    }

    private func planeNode(in rootNode: SCNNode?) -> SCNNode? {
        rootNode?.childNodes.first { $0.name == Self.planeNodeName }
    }

    private func removePlane(from rootNode: SCNNode?) {
        planeNode(in: rootNode)?.removeFromParentNode()
    }

    private static func inPlaneAxes(of axis: StepSectionAxis) -> (StepSectionAxis, StepSectionAxis) {
        switch axis {
        case .x: (.y, .z)
        case .y: (.x, .z)
        case .z: (.x, .y)
        }
    }

    private static func makeSectionPlaneNode(bounds: StepBounds, section: StepSectionPlane, color: PlatformColor) -> SCNNode {
        let axis = section.axis
        let (uAxis, vAxis) = inPlaneAxes(of: axis)
        // Extend a little past the model so the cutting plane reads as a plane.
        let expand: Float = 0.08
        let uMin = bounds.minValue(axis: uAxis), uMax = bounds.maxValue(axis: uAxis)
        let vMin = bounds.minValue(axis: vAxis), vMax = bounds.maxValue(axis: vAxis)
        let uPad = (uMax - uMin) * expand, vPad = (vMax - vMin) * expand
        let u0 = uMin - uPad, u1 = uMax + uPad
        let v0 = vMin - vPad, v1 = vMax + vPad

        func corner(_ u: Float, _ v: Float) -> SCNVector3 {
            var p = SIMD3<Float>(repeating: 0)
            p[axis.index] = section.offset
            p[uAxis.index] = u
            p[vAxis.index] = v
            return SCNVector3(p)
        }
        let positions = [corner(u0, v0), corner(u1, v0), corner(u1, v1), corner(u0, v1)]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: 2, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions)], elements: [element])
        geometry.firstMaterial = StepSectionShader.makeSectionPlaneMaterial(color: color)

        let node = SCNNode(geometry: geometry)
        node.name = planeNodeName
        node.categoryBitMask = planeCategoryBitMask
        node.castsShadow = false
        return node
    }

    // MARK: - Colour

    private func applyColor(_ color: PlatformColor, in rootNode: SCNNode?) {
        if let material = capNode(in: rootNode)?.geometry?.firstMaterial {
            StepSectionShader.setHatchColor(color, on: material)
        }
        if let material = planeNode(in: rootNode)?.geometry?.firstMaterial {
            material.diffuse.contents = color
            material.emission.contents = color
        }
    }
}

private extension StepSceneCameraState {
    init(transform: SCNMatrix4, camera: SCNCamera? = nil) {
        self.init(transform: [
            Float(transform.m11), Float(transform.m12), Float(transform.m13), Float(transform.m14),
            Float(transform.m21), Float(transform.m22), Float(transform.m23), Float(transform.m24),
            Float(transform.m31), Float(transform.m32), Float(transform.m33), Float(transform.m34),
            Float(transform.m41), Float(transform.m42), Float(transform.m43), Float(transform.m44),
        ],
        projection: camera?.usesOrthographicProjection == true ? .orthographic : .perspective,
        orthographicScale: camera?.usesOrthographicProjection == true ? camera?.orthographicScale : nil)
    }

    var sceneKitTransform: SCNMatrix4? {
        guard isValid else {
            return nil
        }

        return SCNMatrix4(
            m11: SceneKitScalar(transform[0]),
            m12: SceneKitScalar(transform[1]),
            m13: SceneKitScalar(transform[2]),
            m14: SceneKitScalar(transform[3]),
            m21: SceneKitScalar(transform[4]),
            m22: SceneKitScalar(transform[5]),
            m23: SceneKitScalar(transform[6]),
            m24: SceneKitScalar(transform[7]),
            m31: SceneKitScalar(transform[8]),
            m32: SceneKitScalar(transform[9]),
            m33: SceneKitScalar(transform[10]),
            m34: SceneKitScalar(transform[11]),
            m41: SceneKitScalar(transform[12]),
            m42: SceneKitScalar(transform[13]),
            m43: SceneKitScalar(transform[14]),
            m44: SceneKitScalar(transform[15])
        )
    }
}

private extension SCNView {
    /// Hit-tests the model at a view point and returns the model-space coordinate
    /// along `axisIndex` for placing a section plane through that surface point,
    /// or `nil` when nothing was hit.
    func sectionOffset(atViewPoint point: CGPoint, axisIndex: Int, boundsCenter: SIMD3<Float>) -> Float? {
        let options: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
            // Skip the section cap/plane so re-picking a section point reads the
            // real surface behind them, not the decorations.
            .categoryBitMask: ~(StepSectionCapController.nonSnappableCategoryBitMask | StepSectionCapController.capCategoryBitMask)
        ]
        let hits = hitTest(point, options: options)
        // Prefer the tessellated mesh; otherwise accept the nearest geometry hit.
        guard let hit = hits.first(where: { $0.node.name == StepSceneFactory.meshNodeName }) ?? hits.first else {
            return nil
        }
        let world = hit.worldCoordinates
        let worldComponent: Float
        switch axisIndex {
        case 0: worldComponent = Float(world.x)
        case 1: worldComponent = Float(world.y)
        default: worldComponent = Float(world.z)
        }
        // world = model - center, so model-space offset = worldComponent + center.
        return worldComponent + boundsCenter[axisIndex]
    }

    /// World-space point where the cutting plane can be grabbed at `point`, or
    /// `nil` when the plane isn't the frontmost thing there (so the gesture should
    /// orbit instead). Geometry the section clips away doesn't block the grab —
    /// it isn't visible, which is exactly where the bare plane shows through.
    func sectionPlaneGrabAnchor(at point: CGPoint, sectionClip: SIMD4<Float>?) -> SIMD3<Float>? {
        let options: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true,
            .categoryBitMask: ~StepMeasurementController.overlayCategoryBitMask
        ]
        for hit in hitTest(point, options: options) {
            let world = SIMD3<Float>(
                Float(hit.worldCoordinates.x),
                Float(hit.worldCoordinates.y),
                Float(hit.worldCoordinates.z)
            )
            switch hit.node.name {
            case StepSectionCapController.planeNodeName:
                return world
            case StepSectionCapController.capNodeName:
                return nil // the cut face is in front: orbit rather than drag
            case StepSceneFactory.meshNodeName:
                if let clip = sectionClip,
                   simd_dot(world, SIMD3<Float>(clip.x, clip.y, clip.z)) > clip.w {
                    continue // clipped away, so not actually in front of the plane
                }
                return nil // solid model in front: orbit rather than drag
            default:
                continue // grid, floor, axes: never block the grab
            }
        }
        return nil
    }

    /// A world-space ray through `point`, valid for both perspective and
    /// orthographic cameras (unprojecting the near and far planes handles both).
    private func worldRay(at point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let near = unprojectPoint(SCNVector3(SceneKitScalar(point.x), SceneKitScalar(point.y), 0))
        let far = unprojectPoint(SCNVector3(SceneKitScalar(point.x), SceneKitScalar(point.y), 1))
        let origin = SIMD3<Float>(Float(near.x), Float(near.y), Float(near.z))
        let delta = SIMD3<Float>(Float(far.x), Float(far.y), Float(far.z)) - origin
        let length = simd_length(delta)
        guard length > 1e-9 else {
            return nil
        }
        return (origin, delta / length)
    }

    /// The section offset the plane should take while being dragged: the point on
    /// the axis line through `anchor` that comes closest to the cursor's ray, so
    /// the plane tracks the pointer along its own axis.
    func sectionDragOffset(
        at point: CGPoint,
        anchor: SIMD3<Float>,
        axisIndex: Int,
        boundsCenter: SIMD3<Float>
    ) -> Float? {
        guard let ray = worldRay(at: point) else {
            return nil
        }
        var axis = SIMD3<Float>(repeating: 0)
        axis[axisIndex] = 1

        let toAnchor = ray.origin - anchor
        let alignment = simd_dot(ray.direction, axis)
        let denominator = 1 - alignment * alignment
        guard abs(denominator) > 1e-5 else {
            return nil // sighting straight down the axis: the drag is ill-defined
        }
        let alongRay = simd_dot(ray.direction, toAnchor)
        let alongAxis = simd_dot(axis, toAnchor)
        let distanceAlongAxis = (alongAxis - alignment * alongRay) / denominator
        let world = anchor + axis * distanceAlongAxis
        return world[axisIndex] + boundsCenter[axisIndex]
    }

    /// Snaps a dragged offset to a nearby model vertex, so the cut lands exactly on
    /// real geometry. Candidates are compared in screen space, which keeps the snap
    /// radius consistent at any zoom.
    func sectionSnappedOffset(
        _ rawOffset: Float,
        anchor: SIMD3<Float>,
        axisIndex: Int,
        boundsCenter: SIMD3<Float>,
        snapModel: StepSnapModel?
    ) -> Float {
        guard let snapModel else {
            return rawOffset
        }
        var planePoint = anchor
        planePoint[axisIndex] = rawOffset - boundsCenter[axisIndex]
        guard let rawScreen = screenPoint(planePoint) else {
            return rawOffset
        }

        var best: Float?
        var bestDistance: Float = 10 // screen points
        for vertex in snapModel.featureVertices(near: planePoint, radius: snapModel.queryRadius * 3) {
            var candidate = planePoint
            candidate[axisIndex] = vertex[axisIndex]
            guard let screen = screenPoint(candidate) else {
                continue
            }
            let distance = simd_distance(screen, rawScreen)
            if distance < bestDistance {
                bestDistance = distance
                best = vertex[axisIndex] + boundsCenter[axisIndex]
            }
        }
        return best ?? rawOffset
    }

    private func screenPoint(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let projected = projectPoint(SCNVector3(world))
        guard projected.z >= 0, projected.z <= 1 else {
            return nil
        }
        return SIMD2<Float>(Float(projected.x), Float(projected.y))
    }
}

#if os(macOS)
private struct StepSceneHostView: NSViewRepresentable {
    var presentation: StepScenePresentation
    var projection: StepCameraProjection
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var interactionInsets: EdgeInsets
    var primaryViewRequest: StepPrimaryViewRequest?
    var section: StepSectionPlane
    var sectionSourceMesh: StepTriangleMesh?
    var sectionColor: PlatformColor
    var boundsCenter: SIMD3<Float>
    var modelID: UUID
    var isPickingSectionPoint: Bool
    var onSectionOffsetPicked: (Float) -> Void
    var measurement: StepMeasurement
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void
    var onMeasureEscape: () -> Void
    @Binding var cameraState: StepSceneCameraState?

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState)
    }

    func makeNSView(context: Context) -> PannableSceneView {
        let view = PannableSceneView()
        view.seedPrimaryViewRequest(primaryViewRequest)
        configure(view, context: context)
        return view
    }

    func updateNSView(_ nsView: PannableSceneView, context: Context) {
        context.coordinator.cameraState = $cameraState
        configure(nsView, context: context)
    }

    private func configure(_ view: PannableSceneView, context: Context) {
        let change = presentation.apply(
            to: view,
            allowsCameraControl: false,
            autoenablesDefaultLighting: false
        )
        if change.changed {
            view.clearLastReportedCameraState()
        }
        view.panningCameraNode = presentation.cameraNode
        view.reverseHorizontalRotation = reverseHorizontalRotation
        view.reverseVerticalRotation = reverseVerticalRotation
        view.interactionInsets = NSEdgeInsets(
            top: interactionInsets.top,
            left: interactionInsets.leading,
            bottom: interactionInsets.bottom,
            right: interactionInsets.trailing
        )
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.sectionAxisIndex = section.axis.index
        view.sectionBoundsCenter = boundsCenter
        view.isPickingSectionPoint = isPickingSectionPoint
        view.isSectionEnabled = section.isEnabled
        view.onSectionOffsetPicked = onSectionOffsetPicked
        StepSectionShader.apply(section, center: boundsCenter, to: presentation.meshMaterials)
        context.coordinator.capController.update(
            modelID: modelID,
            mesh: sectionSourceMesh,
            section: section,
            rootNode: presentation.modelRootNode,
            color: sectionColor,
            center: boundsCenter
        )

        let measurementController = context.coordinator.measurementController
        measurementController.snapModel = snapModel
        measurementController.applyMeasurement(
            measurement,
            scene: presentation.scene,
            largestDimension: snapModel?.largestDimension ?? 1,
            isDarkMode: isDarkMode,
            cameraNode: presentation.cameraNode
        )
        view.snapModel = snapModel
        view.measurementController = measurementController
        view.sectionCapController = context.coordinator.capController
        view.sectionClip = section.isEnabled ? section.clipVector(center: boundsCenter) : nil
        view.isMeasuring = measurement.isActive
        view.onMeasurePointPicked = onMeasurePointPicked
        view.onMeasureEscape = onMeasureEscape
        if !measurement.isActive {
            measurementController.clear(scene: presentation.scene)
        }

        view.applyPrimaryViewRequest(primaryViewRequest)
        view.applyCameraState(cameraState)
        view.applyProjection(projection)
        view.requestThemeFrame(sceneChanged: change.sceneChanged)
    }

    final class Coordinator {
        var cameraState: Binding<StepSceneCameraState?>
        let capController = StepSectionCapController()
        let measurementController = StepMeasurementController()

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

    final class PannableSceneView: SCNView {
        weak var panningCameraNode: SCNNode?
        var onCameraStateChange: ((StepSceneCameraState?) -> Void)?
        var sectionAxisIndex = 0
        var sectionBoundsCenter = SIMD3<Float>(repeating: 0)
        var isPickingSectionPoint = false
        var onSectionOffsetPicked: ((Float) -> Void)?
        var snapModel: StepSnapModel?
        weak var measurementController: StepMeasurementController?
        weak var sectionCapController: StepSectionCapController?
        var isSectionEnabled = false
        // Where the cutting plane was grabbed, while a plane drag is in progress.
        var sectionDragAnchor: SIMD3<Float>?
        // World-space clip plane while sectioning, so snapping can skip the
        // geometry the shader discards. Nil when no section is active.
        var sectionClip: SIMD4<Float>?
        var isMeasuring = false
        var onMeasurePointPicked: ((StepMeasurePoint) -> Void)?
        var onMeasureEscape: (() -> Void)?
        var interactionInsets = NSEdgeInsetsZero
        var reverseHorizontalRotation = false
        var reverseVerticalRotation = false

        private var monitor: Any?
        private var lastReportedCameraState: StepSceneCameraState?
        private var lastOrbitDragLocation: NSPoint?
        private var measureClickLocation: NSPoint?
        // The most recent hover snap, fed back into the resolver for hysteresis so
        // the highlight doesn't flip between neighbouring features.
        private var lastSnapResult: StepSnapResult?
        // Candidates backing the current right-click disambiguation menu, indexed
        // by each menu item's tag.
        private var rightClickCandidates: [StepSnapCandidate] = []

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                removeMonitor()
            }
        }

        private func configureMonitor() {
            removeMonitor()
            guard window != nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { [weak self] event in
                guard let self else {
                    return event
                }
                return self.handle(event)
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else {
                return event
            }

            if event.type == .keyDown {
                // Escape clears the in-progress measurement.
                if isMeasuring, event.keyCode == 53 {
                    onMeasureEscape?()
                    return nil
                }
                return event
            }

            let location = convert(event.locationInWindow, from: nil)
            guard interactionBounds.contains(location) else {
                return event
            }

            if event.type == .magnify {
                let magnification = event.magnification
                guard magnification != 0 else {
                    return nil
                }

                zoomCamera(magnification: magnification, at: location)
                return nil
            }

            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            guard deltaX != 0 || deltaY != 0 else {
                return nil
            }

            if event.hasPreciseScrollingDeltas {
                panCamera(deltaX: deltaX, deltaY: deltaY)
            } else {
                zoomCamera(magnification: deltaY * 0.01, at: location)
            }
            return nil
        }

        private var interactionBounds: NSRect {
            var rect = bounds
            let left = max(interactionInsets.left, 0)
            let right = max(interactionInsets.right, 0)
            let top = max(interactionInsets.top, 0)
            let bottom = max(interactionInsets.bottom, 0)

            rect.origin.x += left
            rect.origin.y += bottom
            rect.size.width = max(rect.width - left - right, 0)
            rect.size.height = max(rect.height - top - bottom, 0)
            return rect
        }

        override func scrollWheel(with event: NSEvent) {
            guard let unhandledEvent = handle(event) else {
                return
            }

            super.scrollWheel(with: unhandledEvent)
        }

        override func magnify(with event: NSEvent) {
            guard handle(event) != nil else {
                return
            }

            super.magnify(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            lastOrbitDragLocation = nil
            sectionDragAnchor = nil
            if isMeasuring, let down = measureClickLocation {
                let location = convert(event.locationInWindow, from: nil)
                // A click (barely moved) commits a measurement point; a drag orbited.
                if hypot(location.x - down.x, location.y - down.y) <= 4 {
                    commitMeasurePoint(at: location)
                }
            }
            measureClickLocation = nil
            reportCameraState()
        }

        override func rightMouseUp(with event: NSEvent) {
            super.rightMouseUp(with: event)
            reportCameraState()
        }

        override func otherMouseUp(with event: NSEvent) {
            super.otherMouseUp(with: event)
            reportCameraState()
        }

        override func mouseDown(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            guard interactionBounds.contains(location) else {
                super.mouseDown(with: event)
                return
            }

            window?.makeFirstResponder(self)

            if isPickingSectionPoint {
                pickSectionOffset(at: location)
                return // consume the click; do not start an orbit drag
            }

            // Grabbing the cutting plane drags it along its axis. Only where the
            // plane is actually the frontmost surface, and never while measuring —
            // the plane spans most of the view and would swallow those clicks.
            if isSectionEnabled, !isMeasuring,
               let anchor = sectionPlaneGrabAnchor(at: location, sectionClip: sectionClip) {
                sectionDragAnchor = anchor
                return // consume the click; do not start an orbit drag
            }

            // While measuring, a plain click commits a point but a drag still orbits.
            if isMeasuring {
                measureClickLocation = location
            }
            lastOrbitDragLocation = location
        }

        /// Moves the section plane to follow the pointer, snapping to nearby vertices.
        private func dragSectionPlane(to location: NSPoint, anchor: SIMD3<Float>) {
            guard let rawOffset = sectionDragOffset(
                at: location,
                anchor: anchor,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter
            ) else {
                return
            }
            onSectionOffsetPicked?(sectionSnappedOffset(
                rawOffset,
                anchor: anchor,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter,
                snapModel: snapModel
            ))
        }

        private func pickSectionOffset(at location: NSPoint) {
            guard let offset = sectionOffset(
                atViewPoint: location,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter
            ) else {
                return
            }
            onSectionOffsetPicked?(offset)
        }

        private func commitMeasurePoint(at location: NSPoint) {
            guard let snapModel,
                  let result = StepSnapResolver.resolve(
                    view: self,
                    snapModel: snapModel,
                    viewPoint: location,
                    sectionSnap: sectionCapController?.sectionSnap,
                    sectionClip: sectionClip,
                    previous: lastSnapResult
                  ) else {
                return
            }
            onMeasurePointPicked?(StepMeasurePoint(position: result.point, kind: result.kind, plane: result.plane, line: result.line, edge: result.edge))
        }

        /// Right-click while measuring lists every snap target under the cursor —
        /// including ones hidden behind the front surface — sorted nearest-first,
        /// so an obscured vertex/edge/face can be picked explicitly.
        override func menu(for event: NSEvent) -> NSMenu? {
            guard isMeasuring, let snapModel else {
                return super.menu(for: event)
            }
            let location = convert(event.locationInWindow, from: nil)
            guard interactionBounds.contains(location) else {
                return nil
            }
            let candidates = StepSnapResolver.candidates(
                view: self,
                snapModel: snapModel,
                viewPoint: location,
                boundsCenter: sectionBoundsCenter,
                sectionSnap: sectionCapController?.sectionSnap,
                sectionClip: sectionClip
            )
            guard !candidates.isEmpty else {
                return nil
            }
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
            guard sender.tag >= 0, sender.tag < rightClickCandidates.count else {
                return
            }
            onMeasurePointPicked?(rightClickCandidates[sender.tag].measurePoint)
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
            measurementController?.clear(scene: scene)
            lastSnapResult = nil
        }

        private func updateMeasurementHighlight(at location: NSPoint) {
            guard isMeasuring, let snapModel, let scene, let controller = measurementController else {
                return
            }
            guard interactionBounds.contains(location) else {
                controller.clear(scene: scene)
                lastSnapResult = nil
                return
            }
            let result = StepSnapResolver.resolve(
                view: self,
                snapModel: snapModel,
                viewPoint: location,
                sectionSnap: sectionCapController?.sectionSnap,
                sectionClip: sectionClip,
                previous: lastSnapResult
            )
            lastSnapResult = result
            controller.applyHighlight(result, scene: scene, largestDimension: snapModel.largestDimension, cameraNode: panningCameraNode ?? pointOfView, sectionClip: sectionClip)
        }

        override func keyDown(with event: NSEvent) {
            // Bare 1–6 and i/d/t jump to the named views (CAD convention).
            // Handled here rather than as menu key equivalents so typing into
            // inspector fields is never intercepted — these fire only with the
            // canvas focused.
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               let characters = event.charactersIgnoringModifiers,
               let primary = StepPrimaryView(key: characters) {
                applyPrimaryView(primary)
                return
            }
            super.keyDown(with: event)
        }

        func applyPrimaryView(_ primary: StepPrimaryView) {
            guard let cameraNode = panningCameraNode ?? pointOfView else { return }
            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41), Double(transform.m42), Double(transform.m43)
            )
            // Keep the current viewing distance; only the direction changes.
            let distance = max(sqrt(dot(position, position)), 0.0001)
            let back = SIMD3<Double>(
                Double(primary.direction.x), Double(primary.direction.y), Double(primary.direction.z)
            )
            let upHint = SIMD3<Double>(
                Double(primary.upHint.x), Double(primary.upHint.y), Double(primary.upHint.z)
            )
            let right = normalized(cross(upHint, back))
            let up = cross(back, right)
            let newPosition = back * distance

            cameraNode.transform = SCNMatrix4(
                m11: SceneKitScalar(right.x), m12: SceneKitScalar(right.y),
                m13: SceneKitScalar(right.z), m14: 0,
                m21: SceneKitScalar(up.x), m22: SceneKitScalar(up.y),
                m23: SceneKitScalar(up.z), m24: 0,
                m31: SceneKitScalar(back.x), m32: SceneKitScalar(back.y),
                m33: SceneKitScalar(back.z), m34: 0,
                m41: SceneKitScalar(newPosition.x), m42: SceneKitScalar(newPosition.y),
                m43: SceneKitScalar(newPosition.z), m44: 1
            )
            reportCameraState()
        }

        /// Menu-driven viewpoint jumps. Only a *change* of request token fires,
        /// so a view recreated by SwiftUI never replays a stale request.
        private var appliedPrimaryViewRequestID: UUID?

        func seedPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
            appliedPrimaryViewRequestID = request?.id
        }

        func applyPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
            guard let request, request.id != appliedPrimaryViewRequestID else { return }
            appliedPrimaryViewRequestID = request.id
            // Deferred a runloop: requests arrive inside a SwiftUI update pass,
            // and the jump reports camera state — a binding write, illegal
            // mid-update.
            DispatchQueue.main.async { [weak self] in
                self?.applyPrimaryView(request.view)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            if let anchor = sectionDragAnchor {
                dragSectionPlane(to: location, anchor: anchor)
                return
            }
            guard let previousLocation = lastOrbitDragLocation else {
                super.mouseDragged(with: event)
                return
            }

            rotateCamera(
                deltaX: location.x - previousLocation.x,
                deltaY: location.y - previousLocation.y
            )
            lastOrbitDragLocation = location
            if let down = measureClickLocation, hypot(location.x - down.x, location.y - down.y) > 4 {
                measureClickLocation = nil // became a drag, not a click
            }
        }

        func applyCameraState(_ state: StepSceneCameraState?) {
            guard let state,
                  state.isValid,
                  state != lastReportedCameraState,
                  let transform = state.sceneKitTransform,
                  let cameraNode = panningCameraNode ?? pointOfView else {
                return
            }

            cameraNode.transform = transform
            applyProjection(state.projection, orthographicScale: state.orthographicScale, reportsChange: false)
            lastReportedCameraState = state
        }

        func clearLastReportedCameraState() {
            lastReportedCameraState = nil
        }

        func requestThemeFrame(sceneChanged: Bool) {
            needsDisplay = true
            layer?.setNeedsDisplay()
            displayIfNeeded()

            guard sceneChanged else {
                return
            }

            isPlaying = true
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
            }
        }

        func applyProjection(_ projection: StepCameraProjection) {
            applyProjection(projection, orthographicScale: nil, reportsChange: false)
        }

        private func applyProjection(
            _ projection: StepCameraProjection,
            orthographicScale: Double?,
            reportsChange: Bool
        ) {
            guard let cameraNode = panningCameraNode ?? pointOfView,
                  let camera = cameraNode.camera else {
                return
            }

            let wantsOrthographic = projection == .orthographic
            if wantsOrthographic, !camera.usesOrthographicProjection {
                // Half the visible height — SCNCamera.orthographicScale is a
                // half-extent, so this keeps the framing across the toggle.
                camera.orthographicScale = orthographicScale ?? visibleHeight(for: cameraNode) / 2
            } else if wantsOrthographic, let orthographicScale {
                camera.orthographicScale = orthographicScale
            }

            guard camera.usesOrthographicProjection != wantsOrthographic else {
                return
            }

            camera.usesOrthographicProjection = wantsOrthographic
            if reportsChange {
                reportCameraState()
            }
        }

        private func panCamera(deltaX: CGFloat, deltaY: CGFloat) {
            guard let cameraNode = panningCameraNode ?? pointOfView else {
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let rightX = transform.m11
            let rightY = transform.m12
            let rightZ = transform.m13
            let upX = transform.m21
            let upY = transform.m22
            let upZ = transform.m23
            let position = cameraNode.position
            let squaredDistance = position.x * position.x
                + position.y * position.y
                + position.z * position.z
            let distance = max(sqrt(squaredDistance), 1)
            let scale = distance * 0.0015
            let x = -deltaX * scale
            let y = deltaY * scale
            let moveX = rightX * x + upX * y
            let moveY = rightY * x + upY * y
            let moveZ = rightZ * x + upZ * y

            cameraNode.position = SCNVector3(
                position.x + moveX,
                position.y + moveY,
                position.z + moveZ
            )
            reportCameraState()
        }

        private func rotateCamera(deltaX: CGFloat, deltaY: CGFloat) {
            guard deltaX != 0 || deltaY != 0,
                  let cameraNode = panningCameraNode ?? pointOfView else {
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let back = normalized(SIMD3<Double>(
                Double(transform.m31),
                Double(transform.m32),
                Double(transform.m33)
            ))
            let distanceToOriginPlane = dot(-position, forward)
            let distance = max(distanceToOriginPlane.isFinite && distanceToOriginPlane > 0 ? distanceToOriginPlane : length(position), 0.0001)
            let target = position + forward * distance
            let offset = position - target
            let yawAngle = (reverseHorizontalRotation ? 1.0 : -1.0) * Double(deltaX) * 0.008
            let pitchAngle = (reverseVerticalRotation ? -1.0 : 1.0) * Double(deltaY) * 0.008

            let yawedOffset = rotated(
                offset,
                around: SIMD3<Double>(0, 1, 0),
                by: yawAngle
            )
            let yawedRight = normalized(rotated(right, around: SIMD3<Double>(0, 1, 0), by: yawAngle))
            let yawedUp = rotated(up, around: SIMD3<Double>(0, 1, 0), by: yawAngle)
            let yawedBack = rotated(back, around: SIMD3<Double>(0, 1, 0), by: yawAngle)
            let pitchedOffset = rotated(yawedOffset, around: yawedRight, by: pitchAngle)
            let pitchedUp = normalized(rotated(yawedUp, around: yawedRight, by: pitchAngle))
            let pitchedBack = normalized(rotated(yawedBack, around: yawedRight, by: pitchAngle))
            let newPosition = target + pitchedOffset

            cameraNode.transform = SCNMatrix4(
                m11: SceneKitScalar(yawedRight.x), m12: SceneKitScalar(yawedRight.y),
                m13: SceneKitScalar(yawedRight.z), m14: 0,
                m21: SceneKitScalar(pitchedUp.x), m22: SceneKitScalar(pitchedUp.y),
                m23: SceneKitScalar(pitchedUp.z), m24: 0,
                m31: SceneKitScalar(pitchedBack.x), m32: SceneKitScalar(pitchedBack.y),
                m33: SceneKitScalar(pitchedBack.z), m34: 0,
                m41: SceneKitScalar(newPosition.x), m42: SceneKitScalar(newPosition.y),
                m43: SceneKitScalar(newPosition.z), m44: 1
            )
            reportCameraState()
        }

        private func zoomCamera(magnification: CGFloat, at location: NSPoint) {
            guard magnification != 0, let cameraNode = panningCameraNode ?? pointOfView else {
                return
            }

            if let camera = cameraNode.camera, camera.usesOrthographicProjection {
                let anchorBefore = worldPointOnFocusPlane(at: location, cameraNode: cameraNode)
                let currentScale = max(camera.orthographicScale, 0.0001)
                let zoomFactor = max(0.05, 1 - Double(magnification * 0.9))
                let newScale = currentScale * zoomFactor
                guard newScale >= 0.02, newScale <= 500_000 else {
                    return
                }

                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0
                camera.orthographicScale = newScale
                if let anchorBefore,
                   let anchorAfter = worldPointOnFocusPlane(at: location, cameraNode: cameraNode) {
                    let offset = anchorBefore - anchorAfter
                    let position = cameraNode.position
                    cameraNode.position = SCNVector3(
                        position.x + SceneKitScalar(offset.x),
                        position.y + SceneKitScalar(offset.y),
                        position.z + SceneKitScalar(offset.z)
                    )
                }
                SCNTransaction.commit()
                reportCameraState()
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            guard let ray = perspectiveRay(at: location, cameraNode: cameraNode, transform: transform) else {
                return
            }

            let focusDistance = focusDistance(position: position, forward: forward)
            let rayDistance = focusDistance / max(dot(ray, forward), 0.0001)
            let zoom = rayDistance * Double(magnification) * 0.9
            let newRayDistance = rayDistance - zoom
            guard newRayDistance >= 0.02, newRayDistance <= 500_000 else {
                return
            }
            let newPosition = position + ray * zoom

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.position = SCNVector3(
                SceneKitScalar(newPosition.x),
                SceneKitScalar(newPosition.y),
                SceneKitScalar(newPosition.z)
            )
            SCNTransaction.commit()
            reportCameraState()
        }

        private func reportCameraState() {
            guard let cameraNode = panningCameraNode ?? pointOfView else {
                onCameraStateChange?(nil)
                return
            }

            let state = StepSceneCameraState(
                transform: cameraNode.presentation.worldTransform,
                camera: cameraNode.camera
            )
            lastReportedCameraState = state
            onCameraStateChange?(state)
        }

        private func visibleHeight(for cameraNode: SCNNode) -> Double {
            guard let camera = cameraNode.camera else {
                return 1
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let distanceToOriginPlane = dot(-position, forward)
            let distance = max(distanceToOriginPlane.isFinite && distanceToOriginPlane > 0 ? distanceToOriginPlane : length(position), 1)
            let fieldOfViewRadians = camera.fieldOfView * .pi / 180
            return max(2 * distance * tan(fieldOfViewRadians / 2), 0.0001)
        }

        private func worldPointOnFocusPlane(at location: NSPoint, cameraNode: SCNNode) -> SIMD3<Double>? {
            guard let camera = cameraNode.camera else {
                return nil
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let focusDistance = focusDistance(position: position, forward: forward)

            if camera.usesOrthographicProjection {
                // orthographicScale is half the visible height, so the world
                // offset at the viewport edge (|x| = 1) is a full half-extent.
                let scale = max(camera.orthographicScale, 0.0001)
                let aspect = max(Double(bounds.width / max(bounds.height, 1)), 0.0001)
                let x = Double((location.x - bounds.midX) / max(bounds.width, 1)) * 2
                let y = Double((location.y - bounds.midY) / max(bounds.height, 1)) * 2
                return position
                    + forward * focusDistance
                    + right * (x * scale * aspect)
                    + up * (y * scale)
            }

            guard let ray = perspectiveRay(at: location, cameraNode: cameraNode, transform: transform) else {
                return nil
            }

            let rayDistance = focusDistance / max(dot(ray, forward), 0.0001)
            return position + ray * rayDistance
        }

        private func perspectiveRay(
            at location: NSPoint,
            cameraNode: SCNNode,
            transform: SCNMatrix4
        ) -> SIMD3<Double>? {
            guard let camera = cameraNode.camera else {
                return nil
            }

            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let aspect = max(Double(bounds.width / max(bounds.height, 1)), 0.0001)
            let x = Double((location.x - bounds.midX) / max(bounds.width, 1)) * 2
            let y = Double((location.y - bounds.midY) / max(bounds.height, 1)) * 2
            let tangent = tan(camera.fieldOfView * .pi / 360)

            return normalized(
                forward
                    + right * (x * tangent * aspect)
                    + up * (y * tangent)
            )
        }

        private func focusDistance(position: SIMD3<Double>, forward: SIMD3<Double>) -> Double {
            let distanceToOriginPlane = dot(-position, forward)
            let fallbackDistance = length(position)
            let distance = distanceToOriginPlane.isFinite && distanceToOriginPlane > 0
                ? distanceToOriginPlane
                : fallbackDistance
            return max(distance, 0.0001)
        }

        private func length(_ vector: SIMD3<Double>) -> Double {
            sqrt(dot(vector, vector))
        }

        private func cross(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(
                lhs.y * rhs.z - lhs.z * rhs.y,
                lhs.z * rhs.x - lhs.x * rhs.z,
                lhs.x * rhs.y - lhs.y * rhs.x
            )
        }

        private func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
            let vectorLength = length(vector)
            guard vectorLength > 0 else {
                return SIMD3<Double>(0, 0, -1)
            }
            return vector / vectorLength
        }

        private func rotated(
            _ vector: SIMD3<Double>,
            around axis: SIMD3<Double>,
            by angle: Double
        ) -> SIMD3<Double> {
            let axis = normalized(axis)
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            return vector * cosAngle
                + cross(axis, vector) * sinAngle
                + axis * dot(axis, vector) * (1 - cosAngle)
        }
    }
}
#elseif canImport(UIKit)
private struct StepSceneHostView: UIViewRepresentable {
    var presentation: StepScenePresentation
    var projection: StepCameraProjection
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var interactionInsets: EdgeInsets
    var primaryViewRequest: StepPrimaryViewRequest?
    var section: StepSectionPlane
    var sectionSourceMesh: StepTriangleMesh?
    var sectionColor: PlatformColor
    var boundsCenter: SIMD3<Float>
    var modelID: UUID
    var isPickingSectionPoint: Bool
    var onSectionOffsetPicked: (Float) -> Void
    var measurement: StepMeasurement
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void
    var onMeasureEscape: () -> Void
    @Binding var cameraState: StepSceneCameraState?

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraState: $cameraState)
    }

    func makeUIView(context: Context) -> TouchSceneView {
        let view = TouchSceneView()
        view.installGestureRecognizersIfNeeded()
        view.seedPrimaryViewRequest(primaryViewRequest)
        configure(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TouchSceneView, context: Context) {
        context.coordinator.cameraState = $cameraState
        configure(uiView, context: context)
    }

    private func configure(_ view: TouchSceneView, context: Context) {
        let change = presentation.apply(
            to: view,
            allowsCameraControl: false,
            autoenablesDefaultLighting: false
        )
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.reverseHorizontalRotation = reverseHorizontalRotation
        view.reverseVerticalRotation = reverseVerticalRotation
        view.sectionAxisIndex = section.axis.index
        view.sectionBoundsCenter = boundsCenter
        view.isPickingSectionPoint = isPickingSectionPoint
        view.isSectionEnabled = section.isEnabled
        view.onSectionOffsetPicked = onSectionOffsetPicked
        StepSectionShader.apply(section, center: boundsCenter, to: presentation.meshMaterials)
        context.coordinator.capController.update(
            modelID: modelID,
            mesh: sectionSourceMesh,
            section: section,
            rootNode: presentation.modelRootNode,
            color: sectionColor,
            center: boundsCenter
        )

        let measurementController = context.coordinator.measurementController
        measurementController.snapModel = snapModel
        measurementController.applyMeasurement(
            measurement,
            scene: presentation.scene,
            largestDimension: snapModel?.largestDimension ?? 1,
            isDarkMode: isDarkMode,
            cameraNode: presentation.cameraNode
        )
        view.snapModel = snapModel
        view.measurementController = measurementController
        view.sectionCapController = context.coordinator.capController
        view.sectionClip = section.isEnabled ? section.clipVector(center: boundsCenter) : nil
        view.isMeasuring = measurement.isActive
        view.onMeasurePointPicked = onMeasurePointPicked
        view.onMeasureEscape = onMeasureEscape
        if !measurement.isActive {
            measurementController.clear(scene: presentation.scene)
        }

        view.applyPrimaryViewRequest(primaryViewRequest)
        view.applyCameraState(cameraState)
        view.applyProjection(projection)
        view.requestThemeFrame(sceneChanged: change.sceneChanged)
    }

    final class Coordinator {
        var cameraState: Binding<StepSceneCameraState?>
        let capController = StepSectionCapController()
        let measurementController = StepMeasurementController()

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

    final class TouchSceneView: SCNView, UIGestureRecognizerDelegate {
        var onCameraStateChange: ((StepSceneCameraState?) -> Void)?
        var reverseHorizontalRotation = false
        var reverseVerticalRotation = false
        var sectionAxisIndex = 0
        var sectionBoundsCenter = SIMD3<Float>(repeating: 0)
        var isPickingSectionPoint = false
        var onSectionOffsetPicked: ((Float) -> Void)?
        var snapModel: StepSnapModel?
        weak var measurementController: StepMeasurementController?
        weak var sectionCapController: StepSectionCapController?
        var isSectionEnabled = false
        // Where the cutting plane was grabbed, while a plane drag is in progress.
        var sectionDragAnchor: SIMD3<Float>?
        // World-space clip plane while sectioning, so snapping can skip the
        // geometry the shader discards. Nil when no section is active.
        var sectionClip: SIMD4<Float>?
        var isMeasuring = false
        var onMeasurePointPicked: ((StepMeasurePoint) -> Void)?
        var onMeasureEscape: (() -> Void)?

        private var didConfigureTouchHandling = false
        private var activeTouches = Set<UITouch>()
        private var sectionPickTouchStart: CGPoint?
        private var measureTouchStart: CGPoint?
        private var lastSingleTouchLocation: CGPoint?
        private var lastTwoFingerCentroid: CGPoint?
        private var lastTwoFingerDistance: CGFloat?
        private var lastTrackpadPinchScale: CGFloat = 1
        // The most recent hover/tap snap, fed back into the resolver for hysteresis
        // so the highlight doesn't flip between neighbouring features.
        private var lastSnapResult: StepSnapResult?
        // Whether the current single-touch gesture came from an Apple Pencil.
        private var pencilTouchActive = false

        /// The Pencil acts as a precision instrument — selecting, never orbiting —
        /// but only while a tool is active. With no tool on it orbits like a finger,
        /// so someone holding the Pencil can still look around one-handed.
        private var isPencilPrecisionGesture: Bool {
            pencilTouchActive && (isMeasuring || isPickingSectionPoint)
        }

        func installGestureRecognizersIfNeeded() {
            guard !didConfigureTouchHandling else {
                return
            }

            isMultipleTouchEnabled = true

            // Trackpad input is indirect and never arrives through touchesMoved(_:),
            // so route it through gesture recognizers. Two-finger trackpad scrolling
            // pans and trackpad pinching zooms, matching macOS. Direct touches keep
            // flowing to the touch handlers (the recognizers don't cancel them, and
            // the pinch handler ignores anything with on-screen touches).
            let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            scrollPan.allowedScrollTypesMask = .continuous
            scrollPan.maximumNumberOfTouches = 0
            scrollPan.cancelsTouchesInView = false
            scrollPan.delegate = self
            addGestureRecognizer(scrollPan)

            let scrollPinch = UIPinchGestureRecognizer(target: self, action: #selector(handleScrollPinch(_:)))
            scrollPinch.cancelsTouchesInView = false
            scrollPinch.delegate = self
            addGestureRecognizer(scrollPinch)

            // Hovering — a trackpad/mouse pointer, or an Apple Pencil held just above
            // the display — previews what a tap would snap to, the same way the
            // pointer does on macOS.
            //
            // `allowedTouchTypes` lists every type rather than just pointer+pencil:
            // the default is documented only as "platform dependent", and narrowing
            // it is a silent failure — the recognizer simply never fires. Direct and
            // indirect touches don't generate hover events, so listing them costs
            // nothing and guarantees nothing is excluded.
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hover.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirect.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
            // Without this the recognizer latches onto whichever type it sees first
            // and ignores the other for the rest of the gesture, so a connected
            // pointer would shut out Pencil hover (and vice versa).
            hover.requiresExclusiveTouchType = false
            hover.cancelsTouchesInView = false
            hover.delegate = self
            addGestureRecognizer(hover)

            didConfigureTouchHandling = true
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                updateMeasurementHighlight(at: recognizer.location(in: self))
            default:
                // Pointer left the view, or the Pencil moved out of range.
                clearMeasurementHighlight()
            }
        }

        /// Previews the snap under `location` without committing it.
        private func updateMeasurementHighlight(at location: CGPoint) {
            guard isMeasuring, let snapModel, let scene, let controller = measurementController else {
                return
            }
            guard bounds.contains(location) else {
                clearMeasurementHighlight()
                return
            }
            let result = StepSnapResolver.resolve(
                view: self,
                snapModel: snapModel,
                viewPoint: location,
                sectionSnap: sectionCapController?.sectionSnap,
                sectionClip: sectionClip,
                previous: lastSnapResult
            )
            lastSnapResult = result
            controller.applyHighlight(result, scene: scene, largestDimension: snapModel.largestDimension, cameraNode: pointOfView, sectionClip: sectionClip)
        }

        private func clearMeasurementHighlight() {
            lastSnapResult = nil
            if let scene {
                measurementController?.clear(scene: scene)
            }
        }

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let translation = recognizer.translation(in: self)
                panCamera(deltaX: translation.x, deltaY: translation.y)
                recognizer.setTranslation(.zero, in: self)
            case .ended, .cancelled, .failed:
                reportCameraState()
            default:
                break
            }
        }

        @objc private func handleScrollPinch(_ recognizer: UIPinchGestureRecognizer) {
            // Only handle indirect (trackpad) pinches here. A direct two-finger
            // pinch reports its on-screen touches and is handled by the raw touch
            // logic, which also pans with the gesture centroid.
            guard recognizer.numberOfTouches == 0 else {
                return
            }

            switch recognizer.state {
            case .began:
                lastTrackpadPinchScale = recognizer.scale
            case .changed:
                let scale = max(recognizer.scale, 0.0001)
                let scaleDelta = scale / max(lastTrackpadPinchScale, 0.0001)
                lastTrackpadPinchScale = scale
                zoomCamera(scaleDelta: scaleDelta, at: recognizer.location(in: self), reportsChange: false)
                reportCameraState()
            case .ended, .cancelled, .failed:
                lastTrackpadPinchScale = 1
                reportCameraState()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

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
            StepPrimaryView.allKeys.map { key in
                UIKeyCommand(
                    input: key,
                    modifierFlags: [],
                    action: #selector(handlePrimaryViewKey(_:))
                )
            }
        }

        @objc private func handlePrimaryViewKey(_ command: UIKeyCommand) {
            guard let input = command.input, let primary = StepPrimaryView(key: input) else { return }
            applyPrimaryView(primary)
        }

        func applyPrimaryView(_ primary: StepPrimaryView) {
            guard let cameraNode = pointOfView else { return }
            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41), Double(transform.m42), Double(transform.m43)
            )
            let distance = max(sqrt(dot(position, position)), 0.0001)
            let back = SIMD3<Double>(
                Double(primary.direction.x), Double(primary.direction.y), Double(primary.direction.z)
            )
            let upHint = SIMD3<Double>(
                Double(primary.upHint.x), Double(primary.upHint.y), Double(primary.upHint.z)
            )
            let right = normalized(cross(upHint, back))
            let up = cross(back, right)
            let newPosition = back * distance

            cameraNode.transform = SCNMatrix4(
                m11: SceneKitScalar(right.x), m12: SceneKitScalar(right.y),
                m13: SceneKitScalar(right.z), m14: 0,
                m21: SceneKitScalar(up.x), m22: SceneKitScalar(up.y),
                m23: SceneKitScalar(up.z), m24: 0,
                m31: SceneKitScalar(back.x), m32: SceneKitScalar(back.y),
                m33: SceneKitScalar(back.z), m34: 0,
                m41: SceneKitScalar(newPosition.x), m42: SceneKitScalar(newPosition.y),
                m43: SceneKitScalar(newPosition.z), m44: 1
            )
            reportCameraState()
        }

        /// Menu-driven viewpoint jumps. Only a *change* of request token fires,
        /// so a view recreated by SwiftUI never replays a stale request.
        private var appliedPrimaryViewRequestID: UUID?

        func seedPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
            appliedPrimaryViewRequestID = request?.id
        }

        func applyPrimaryViewRequest(_ request: StepPrimaryViewRequest?) {
            guard let request, request.id != appliedPrimaryViewRequestID else { return }
            appliedPrimaryViewRequestID = request.id
            // Deferred a runloop: requests arrive inside a SwiftUI update pass,
            // and the jump reports camera state — a binding write, illegal
            // mid-update.
            DispatchQueue.main.async { [weak self] in
                self?.applyPrimaryView(request.view)
            }
        }

        func requestThemeFrame(sceneChanged: Bool) {
            setNeedsDisplay()
            layer.setNeedsDisplay()

            guard sceneChanged else {
                return
            }

            isPlaying = true
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = false
            }
        }

        func applyCameraState(_ state: StepSceneCameraState?) {
            guard let state,
                  state.isValid,
                  let transform = state.sceneKitTransform,
                  let pointOfView else {
                return
            }

            pointOfView.transform = transform
            applyProjection(state.projection, orthographicScale: state.orthographicScale)
        }

        func applyProjection(_ projection: StepCameraProjection) {
            applyProjection(projection, orthographicScale: nil)
        }

        private func applyProjection(_ projection: StepCameraProjection, orthographicScale: Double?) {
            guard let cameraNode = pointOfView, let camera = cameraNode.camera else {
                return
            }

            let wantsOrthographic = projection == .orthographic
            if wantsOrthographic, !camera.usesOrthographicProjection {
                // Half the visible height — SCNCamera.orthographicScale is a
                // half-extent, so this keeps the framing across the toggle.
                camera.orthographicScale = orthographicScale ?? visibleHeight(for: cameraNode) / 2
            } else if wantsOrthographic, let orthographicScale {
                camera.orthographicScale = orthographicScale
            }
            camera.usesOrthographicProjection = wantsOrthographic
        }

        private func visibleHeight(for cameraNode: SCNNode) -> Double {
            guard let camera = cameraNode.camera else {
                return 1
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let distance = focusDistance(position: position, forward: forward)
            let fieldOfViewRadians = camera.fieldOfView * .pi / 180
            return max(2 * distance * tan(fieldOfViewRadians / 2), 0.0001)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouches.formUnion(touches)
            pencilTouchActive = activeTouches.count == 1 && activeTouches.first?.type == .pencil
            if isPickingSectionPoint, activeTouches.count == 1 {
                sectionPickTouchStart = touches.first?.location(in: self)
            } else {
                sectionPickTouchStart = nil
            }
            if isMeasuring, activeTouches.count == 1 {
                measureTouchStart = touches.first?.location(in: self)
            } else {
                measureTouchStart = nil
            }
            // One finger landing on the cutting plane drags it; a second finger
            // cancels the drag so pinch-to-zoom still works.
            if isSectionEnabled, !isPickingSectionPoint, !isMeasuring, activeTouches.count == 1,
               let location = touches.first?.location(in: self) {
                sectionDragAnchor = sectionPlaneGrabAnchor(at: location, sectionClip: sectionClip)
            } else {
                sectionDragAnchor = nil
            }
            resetTouchBaseline()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            // The Pencil never orbits while a tool is active. Dragging it scrubs the
            // preview instead, so you can slide onto the exact feature and lift.
            if isPencilPrecisionGesture, activeTouches.count == 1 {
                if isMeasuring, let location = touches.first?.location(in: self) {
                    updateMeasurementHighlight(at: location)
                }
                return
            }
            // While picking a section point, a single finger must not orbit.
            if isPickingSectionPoint, activeTouches.count == 1 {
                return
            }
            // Dragging the cutting plane takes the gesture instead of orbiting.
            if let anchor = sectionDragAnchor, activeTouches.count == 1 {
                if let location = touches.first?.location(in: self) {
                    dragSectionPlane(to: location, anchor: anchor)
                }
                return
            }
            // While measuring, a single finger still orbits; a drift cancels the tap.
            if isMeasuring, activeTouches.count == 1, let start = measureTouchStart,
               let location = touches.first?.location(in: self),
               hypot(location.x - start.x, location.y - start.y) > 12 {
                measureTouchStart = nil
            }
            switch activeTouches.count {
            case 1:
                handleSingleTouchMove()
            case 2:
                handleTwoFingerMove()
            default:
                clearTouchBaseline()
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if isPencilPrecisionGesture, activeTouches.count == 1,
               let end = touches.first?.location(in: self) {
                // The Pencil never orbited, so there is nothing to disambiguate a tap
                // from: any lift commits where the tip left off, rather than demanding
                // a near-stationary tap from a fine-tipped stylus.
                if isPickingSectionPoint {
                    pickSectionOffset(at: end)
                } else if isMeasuring {
                    commitMeasurePoint(at: end)
                }
            } else {
                // Fingers orbit, so only a tap that barely moved counts as a pick.
                if isPickingSectionPoint, let start = sectionPickTouchStart,
                   activeTouches.count == 1, let end = touches.first?.location(in: self),
                   hypot(end.x - start.x, end.y - start.y) <= 12 {
                    pickSectionOffset(at: end)
                }
                if isMeasuring, let start = measureTouchStart,
                   activeTouches.count == 1, let end = touches.first?.location(in: self),
                   hypot(end.x - start.x, end.y - start.y) <= 12 {
                    commitMeasurePoint(at: end)
                }
            }
            pencilTouchActive = false
            sectionPickTouchStart = nil
            measureTouchStart = nil
            sectionDragAnchor = nil
            activeTouches.subtract(touches)
            resetTouchBaseline()
            reportCameraState()
        }

        private func pickSectionOffset(at location: CGPoint) {
            guard let offset = sectionOffset(
                atViewPoint: location,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter
            ) else {
                return
            }
            onSectionOffsetPicked?(offset)
        }

        /// Moves the section plane to follow the touch, snapping to nearby vertices.
        private func dragSectionPlane(to location: CGPoint, anchor: SIMD3<Float>) {
            guard let rawOffset = sectionDragOffset(
                at: location,
                anchor: anchor,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter
            ) else {
                return
            }
            onSectionOffsetPicked?(sectionSnappedOffset(
                rawOffset,
                anchor: anchor,
                axisIndex: sectionAxisIndex,
                boundsCenter: sectionBoundsCenter,
                snapModel: snapModel
            ))
        }

        private func commitMeasurePoint(at location: CGPoint) {
            // `previous` carries the hovered feature through, so a Pencil or pointer
            // tap commits exactly what was highlighted rather than re-resolving and
            // possibly landing on a neighbour.
            guard let snapModel,
                  let result = StepSnapResolver.resolve(
                    view: self,
                    snapModel: snapModel,
                    viewPoint: location,
                    sectionSnap: sectionCapController?.sectionSnap,
                    sectionClip: sectionClip,
                    previous: lastSnapResult
                  ) else {
                return
            }
            lastSnapResult = result
            onMeasurePointPicked?(StepMeasurePoint(position: result.point, kind: result.kind, plane: result.plane, line: result.line, edge: result.edge))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            pencilTouchActive = false
            sectionDragAnchor = nil
            activeTouches.subtract(touches)
            resetTouchBaseline()
            reportCameraState()
        }

        private func handleSingleTouchMove() {
            guard let location = singleTouchLocation() else {
                clearTouchBaseline()
                return
            }
            guard let previousLocation = lastSingleTouchLocation else {
                resetTouchBaseline()
                return
            }

            let deltaX = location.x - previousLocation.x
            let deltaY = location.y - previousLocation.y
            rotateCamera(deltaX: deltaX, deltaY: deltaY)
            lastSingleTouchLocation = location
        }

        private func handleTwoFingerMove() {
            guard let metrics = twoFingerMetrics() else {
                clearTouchBaseline()
                return
            }
            guard let previousCentroid = lastTwoFingerCentroid,
                  let previousDistance = lastTwoFingerDistance,
                  previousDistance > 0 else {
                resetTouchBaseline()
                return
            }

            let scaleDelta = metrics.distance / previousDistance
            zoomCamera(
                scaleDelta: scaleDelta,
                at: metrics.centroid,
                anchoredFrom: previousCentroid,
                reportsChange: false
            )
            lastTwoFingerCentroid = metrics.centroid
            lastTwoFingerDistance = metrics.distance
            reportCameraState()
        }

        private func resetTouchBaseline() {
            switch activeTouches.count {
            case 1:
                lastSingleTouchLocation = singleTouchLocation()
                lastTwoFingerCentroid = nil
                lastTwoFingerDistance = nil
            case 2:
                if let metrics = twoFingerMetrics() {
                    lastSingleTouchLocation = nil
                    lastTwoFingerCentroid = metrics.centroid
                    lastTwoFingerDistance = metrics.distance
                } else {
                    clearTouchBaseline()
                }
            default:
                clearTouchBaseline()
            }
        }

        private func clearTouchBaseline() {
            lastSingleTouchLocation = nil
            lastTwoFingerCentroid = nil
            lastTwoFingerDistance = nil
        }

        private func singleTouchLocation() -> CGPoint? {
            activeTouches.first?.location(in: self)
        }

        private func twoFingerMetrics() -> (centroid: CGPoint, distance: CGFloat)? {
            let locations = activeTouches.prefix(2).map { $0.location(in: self) }
            guard locations.count == 2 else {
                return nil
            }

            let first = locations[0]
            let second = locations[1]
            let centroid = CGPoint(
                x: (first.x + second.x) / 2,
                y: (first.y + second.y) / 2
            )
            let distance = max(hypot(second.x - first.x, second.y - first.y), 0.0001)
            return (centroid, distance)
        }

        private func panCamera(deltaX: CGFloat, deltaY: CGFloat) {
            guard deltaX != 0 || deltaY != 0,
                  let cameraNode = pointOfView else {
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let distance = focusDistance(position: position, forward: forward)
            let scale = distance * 0.0015
            let offset = right * (-Double(deltaX) * scale) + up * (Double(deltaY) * scale)
            let newPosition = position + offset

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.position = SCNVector3(
                SceneKitScalar(newPosition.x),
                SceneKitScalar(newPosition.y),
                SceneKitScalar(newPosition.z)
            )
            SCNTransaction.commit()
            reportCameraState()
        }

        private func rotateCamera(deltaX: CGFloat, deltaY: CGFloat) {
            guard deltaX != 0 || deltaY != 0,
                  let cameraNode = pointOfView else {
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let back = normalized(SIMD3<Double>(
                Double(transform.m31),
                Double(transform.m32),
                Double(transform.m33)
            ))
            let distance = focusDistance(position: position, forward: forward)
            let target = position + forward * distance
            let offset = position - target
            let yawAngle = (reverseHorizontalRotation ? 1.0 : -1.0) * Double(deltaX) * 0.008
            let pitchAngle = (reverseVerticalRotation ? -1.0 : 1.0) * Double(deltaY) * 0.008

            let yawedOffset = rotated(
                offset,
                around: SIMD3<Double>(0, 1, 0),
                by: yawAngle
            )
            let yawedRight = normalized(rotated(right, around: SIMD3<Double>(0, 1, 0), by: yawAngle))
            let yawedUp = rotated(up, around: SIMD3<Double>(0, 1, 0), by: yawAngle)
            let yawedBack = rotated(back, around: SIMD3<Double>(0, 1, 0), by: yawAngle)
            let pitchedOffset = rotated(yawedOffset, around: yawedRight, by: pitchAngle)
            let pitchedUp = normalized(rotated(yawedUp, around: yawedRight, by: pitchAngle))
            let pitchedBack = normalized(rotated(yawedBack, around: yawedRight, by: pitchAngle))
            let newPosition = target + pitchedOffset

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.transform = SCNMatrix4(
                m11: SceneKitScalar(yawedRight.x), m12: SceneKitScalar(yawedRight.y),
                m13: SceneKitScalar(yawedRight.z), m14: 0,
                m21: SceneKitScalar(pitchedUp.x), m22: SceneKitScalar(pitchedUp.y),
                m23: SceneKitScalar(pitchedUp.z), m24: 0,
                m31: SceneKitScalar(pitchedBack.x), m32: SceneKitScalar(pitchedBack.y),
                m33: SceneKitScalar(pitchedBack.z), m34: 0,
                m41: SceneKitScalar(newPosition.x), m42: SceneKitScalar(newPosition.y),
                m43: SceneKitScalar(newPosition.z), m44: 1
            )
            SCNTransaction.commit()
            reportCameraState()
        }

        private func zoomCamera(
            scaleDelta: CGFloat,
            at location: CGPoint,
            anchoredFrom anchorLocation: CGPoint? = nil,
            reportsChange: Bool = true
        ) {
            guard scaleDelta.isFinite,
                  scaleDelta > 0,
                  let cameraNode = pointOfView else {
                return
            }

            let anchorLocation = anchorLocation ?? location
            if let camera = cameraNode.camera, camera.usesOrthographicProjection {
                let anchorBefore = worldPointOnFocusPlane(at: anchorLocation, cameraNode: cameraNode)
                let currentScale = max(camera.orthographicScale, 0.0001)
                let requestedScale = currentScale / Double(scaleDelta)
                let newScale = min(max(requestedScale, 0.02), 500_000)

                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0
                camera.orthographicScale = newScale
                if let anchorBefore,
                   let anchorAfter = worldPointOnFocusPlane(at: location, cameraNode: cameraNode) {
                    let offset = anchorBefore - anchorAfter
                    let position = cameraNode.position
                    cameraNode.position = SCNVector3(
                        position.x + SceneKitScalar(offset.x),
                        position.y + SceneKitScalar(offset.y),
                        position.z + SceneKitScalar(offset.z)
                    )
                }
                SCNTransaction.commit()
                if reportsChange {
                    reportCameraState()
                }
                return
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            guard let ray = perspectiveRay(at: location, cameraNode: cameraNode, transform: transform) else {
                return
            }
            let anchorBefore = worldPointOnFocusPlane(at: anchorLocation, cameraNode: cameraNode)

            let focusDistance = focusDistance(position: position, forward: forward)
            let rayDistance = focusDistance / max(dot(ray, forward), 0.0001)
            let requestedRayDistance = rayDistance / Double(scaleDelta)
            let newRayDistance = min(max(requestedRayDistance, 0.02), 500_000)
            let zoom = rayDistance - newRayDistance
            let anchorAfter = position + ray * rayDistance
            let anchorOffset = anchorBefore.map { $0 - anchorAfter } ?? SIMD3<Double>(0, 0, 0)
            let newPosition = position + ray * zoom + anchorOffset

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            cameraNode.position = SCNVector3(
                SceneKitScalar(newPosition.x),
                SceneKitScalar(newPosition.y),
                SceneKitScalar(newPosition.z)
            )
            SCNTransaction.commit()
            if reportsChange {
                reportCameraState()
            }
        }

        private func reportCameraState() {
            guard let pointOfView else {
                onCameraStateChange?(nil)
                return
            }

            onCameraStateChange?(StepSceneCameraState(transform: pointOfView.transform, camera: pointOfView.camera))
        }

        private func worldPointOnFocusPlane(at location: CGPoint, cameraNode: SCNNode) -> SIMD3<Double>? {
            guard let camera = cameraNode.camera else {
                return nil
            }

            let transform = cameraNode.presentation.worldTransform
            let position = SIMD3<Double>(
                Double(transform.m41),
                Double(transform.m42),
                Double(transform.m43)
            )
            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let focusDistance = focusDistance(position: position, forward: forward)

            if camera.usesOrthographicProjection {
                // orthographicScale is half the visible height, so the world
                // offset at the viewport edge (|x| = 1) is a full half-extent.
                let scale = max(camera.orthographicScale, 0.0001)
                let aspect = max(Double(bounds.width / max(bounds.height, 1)), 0.0001)
                let x = Double((location.x - bounds.midX) / max(bounds.width, 1)) * 2
                let y = Double((bounds.midY - location.y) / max(bounds.height, 1)) * 2
                return position
                    + forward * focusDistance
                    + right * (x * scale * aspect)
                    + up * (y * scale)
            }

            guard let ray = perspectiveRay(at: location, cameraNode: cameraNode, transform: transform) else {
                return nil
            }

            let rayDistance = focusDistance / max(dot(ray, forward), 0.0001)
            return position + ray * rayDistance
        }

        private func perspectiveRay(
            at location: CGPoint,
            cameraNode: SCNNode,
            transform: SCNMatrix4
        ) -> SIMD3<Double>? {
            guard let camera = cameraNode.camera else {
                return nil
            }

            let right = normalized(SIMD3<Double>(
                Double(transform.m11),
                Double(transform.m12),
                Double(transform.m13)
            ))
            let up = normalized(SIMD3<Double>(
                Double(transform.m21),
                Double(transform.m22),
                Double(transform.m23)
            ))
            let forward = normalized(SIMD3<Double>(
                -Double(transform.m31),
                -Double(transform.m32),
                -Double(transform.m33)
            ))
            let aspect = max(Double(bounds.width / max(bounds.height, 1)), 0.0001)
            let x = Double((location.x - bounds.midX) / max(bounds.width, 1)) * 2
            let y = Double((bounds.midY - location.y) / max(bounds.height, 1)) * 2
            let tangent = tan(camera.fieldOfView * .pi / 360)

            return normalized(
                forward
                    + right * (x * tangent * aspect)
                    + up * (y * tangent)
            )
        }

        private func focusDistance(position: SIMD3<Double>, forward: SIMD3<Double>) -> Double {
            let distanceToOriginPlane = dot(-position, forward)
            let fallbackDistance = length(position)
            let distance = distanceToOriginPlane.isFinite && distanceToOriginPlane > 0
                ? distanceToOriginPlane
                : fallbackDistance
            return max(distance, 0.0001)
        }

        private func length(_ vector: SIMD3<Double>) -> Double {
            sqrt(dot(vector, vector))
        }

        private func cross(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(
                lhs.y * rhs.z - lhs.z * rhs.y,
                lhs.z * rhs.x - lhs.x * rhs.z,
                lhs.x * rhs.y - lhs.y * rhs.x
            )
        }

        private func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
            let vectorLength = length(vector)
            guard vectorLength > 0 else {
                return SIMD3<Double>(0, 0, -1)
            }
            return vector / vectorLength
        }

        private func rotated(
            _ vector: SIMD3<Double>,
            around axis: SIMD3<Double>,
            by angle: Double
        ) -> SIMD3<Double> {
            let axis = normalized(axis)
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            return vector * cosAngle
                + cross(axis, vector) * sinAngle
                + axis * dot(axis, vector) * (1 - cosAngle)
        }
    }
}
#endif
