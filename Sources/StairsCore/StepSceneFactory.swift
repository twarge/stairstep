import Foundation
import SceneKit

#if os(macOS)
private typealias SceneKitScalar = CGFloat
#else
private typealias SceneKitScalar = Float
#endif

public struct StepSceneViewChange {
    public var sceneChanged: Bool
    public var cameraChanged: Bool

    public var changed: Bool {
        sceneChanged || cameraChanged
    }
}

public struct StepScenePresentation {
    public var scene: SCNScene
    public var cameraNode: SCNNode
    public var backgroundColor: PlatformColor

    @MainActor
    @discardableResult
    public func apply(
        to sceneView: SCNView,
        allowsCameraControl: Bool,
        autoenablesDefaultLighting: Bool = false,
        antialiasingMode: SCNAntialiasingMode = .multisampling4X
    ) -> StepSceneViewChange {
        let sceneChanged = sceneView.scene !== scene
        let cameraChanged = sceneView.pointOfView !== cameraNode

        scene.background.contents = backgroundColor
        sceneView.backgroundColor = backgroundColor
        sceneView.allowsCameraControl = allowsCameraControl
        sceneView.autoenablesDefaultLighting = autoenablesDefaultLighting
        sceneView.antialiasingMode = antialiasingMode

        if sceneChanged {
            sceneView.scene = scene
        }
        if cameraChanged {
            sceneView.pointOfView = cameraNode
        }

        return StepSceneViewChange(sceneChanged: sceneChanged, cameraChanged: cameraChanged)
    }
}

public extension StepScenePresentation {
    /// Clip-capable materials of the tessellated mesh, if present.
    var meshMaterials: [SCNMaterial] {
        scene.rootNode
            .childNode(withName: StepSceneFactory.meshNodeName, recursively: true)?
            .geometry?.materials ?? []
    }

    /// The centered model container the cross-section cap should be parented to.
    var modelRootNode: SCNNode? {
        scene.rootNode.childNode(withName: StepSceneFactory.modelRootNodeName, recursively: true)
    }
}

public enum StepSceneFactory {
    /// Node name of the centered model container. The cross-section cap is hung
    /// here so it shares the model's `-center` offset and coordinate space.
    public static let modelRootNodeName = "Model root"
    /// Node name of the tessellated mesh, used to reach its clip materials.
    public static let meshNodeName = "STEP mesh"

    public static func presentation(
        for model: StepModel,
        options: StepSceneOptions,
        section: StepSectionPlane = StepSectionPlane(),
        isDarkMode: Bool
    ) -> StepScenePresentation {
        let backgroundColor = PlatformColor.stairsBackground(isDarkMode: isDarkMode)
        let scene = SCNScene()
        scene.background.contents = backgroundColor

        let centeredModelNode = SCNNode()
        centeredModelNode.name = modelRootNodeName
        centeredModelNode.position = SCNVector3(-model.bounds.center.x, -model.bounds.center.y, -model.bounds.center.z)

        if let mesh = model.mesh,
           let meshNode = meshNode(for: mesh, options: options) {
            if let materials = meshNode.geometry?.materials {
                StepSectionShader.install(on: materials)
                StepSectionShader.apply(section, center: model.bounds.center, to: materials)
            }
            centeredModelNode.addChildNode(meshNode)
        } else {
            centeredModelNode.addChildNode(boundsNode(for: model.bounds))
        }
        scene.rootNode.addChildNode(centeredModelNode)

        if options.showsFloor {
            addShadowFloor(to: scene, bounds: model.bounds, isDarkMode: isDarkMode)
        }
        if options.showsGrid {
            addGrid(to: scene, bounds: model.bounds)
        }
        if options.showsAxes {
            addAxes(to: scene, bounds: model.bounds)
        }
        addLighting(
            to: scene,
            bounds: model.bounds,
            isDarkMode: isDarkMode,
            usesColoredAccentLights: options.usesColoredAccentLights
        )
        let cameraNode = addCamera(to: scene, bounds: model.bounds)
        return StepScenePresentation(scene: scene, cameraNode: cameraNode, backgroundColor: backgroundColor)
    }

    public static func scene(
        for model: StepModel,
        options: StepSceneOptions,
        isDarkMode: Bool
    ) -> (scene: SCNScene, cameraNode: SCNNode) {
        let presentation = presentation(for: model, options: options, isDarkMode: isDarkMode)
        return (presentation.scene, presentation.cameraNode)
    }

    private static func meshNode(for mesh: StepTriangleMesh, options: StepSceneOptions) -> SCNNode? {
        let vertices = mesh.vertices.map { SCNVector3($0.position) }
        let normals = mesh.vertices.map { SCNVector3($0.normal) }
        var indicesByMaterial = [StepMaterialKey: [UInt32]]()
        let neutralKey = StepMaterialKey(red: 178, green: 186, blue: 194)

        for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
            let firstIndex = Int(mesh.indices[triangleStart])
            guard firstIndex >= 0 && firstIndex < mesh.vertices.count else {
                continue
            }

            let key = options.usesOriginalColors
                ? StepMaterialKey(color: mesh.vertices[firstIndex].color)
                : neutralKey
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart])
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart + 1])
            indicesByMaterial[key, default: []].append(mesh.indices[triangleStart + 2])
        }

        let sortedKeys = indicesByMaterial.keys.sorted()
        let elements = sortedKeys.compactMap { key -> SCNGeometryElement? in
            guard let indices = indicesByMaterial[key], !indices.isEmpty else {
                return nil
            }

            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }

        guard !elements.isEmpty else {
            return nil
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals)
            ],
            elements: elements
        )
        geometry.materials = sortedKeys.map { key in
            let material = SCNMaterial()
            let color = key.platformColor
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.07)
            material.specular.contents = PlatformColor.white.withAlphaComponent(0.28)
            material.reflective.contents = PlatformColor.white.withAlphaComponent(0.04)
            material.roughness.contents = 0.42
            material.metalness.contents = 0.0
            material.shininess = 0.18
            material.fillMode = options.showsWireframe ? .lines : .fill
            material.isDoubleSided = options.showsWireframe
            return material
        }

        let node = SCNNode(geometry: geometry)
        node.name = meshNodeName
        return node
    }

    private static func boundsNode(for bounds: StepBounds) -> SCNNode {
        let size = paddedSize(for: bounds)
        let chamfer = CGFloat(max(min(bounds.largestDimension * 0.006, 0.12), 0.01))
        let solidGeometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: chamfer
        )
        let solidMaterial = SCNMaterial()
        solidMaterial.diffuse.contents = PlatformColor.stairsNeutralModel.withAlphaComponent(0.54)
        solidMaterial.emission.contents = PlatformColor.stairsNeutralModel.withAlphaComponent(0.05)
        solidMaterial.specular.contents = PlatformColor.white.withAlphaComponent(0.18)
        solidMaterial.roughness.contents = 0.58
        solidMaterial.transparency = 0.54
        solidGeometry.firstMaterial = solidMaterial

        let solidNode = SCNNode(geometry: solidGeometry)
        solidNode.position = SCNVector3(bounds.center)

        let wireGeometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: chamfer
        )
        let wireMaterial = SCNMaterial()
        wireMaterial.diffuse.contents = PlatformColor.white.withAlphaComponent(0.36)
        wireMaterial.emission.contents = PlatformColor.white.withAlphaComponent(0.10)
        wireMaterial.fillMode = .lines
        wireGeometry.firstMaterial = wireMaterial

        let wireNode = SCNNode(geometry: wireGeometry)
        wireNode.position = solidNode.position

        let parent = SCNNode()
        parent.name = "STEP bounds"
        parent.addChildNode(solidNode)
        parent.addChildNode(wireNode)
        return parent
    }

    private static func paddedSize(for bounds: StepBounds) -> SIMD3<Float> {
        SIMD3<Float>(
            max(bounds.width, 0.05),
            max(bounds.height, 0.05),
            max(bounds.depth, 0.05)
        )
    }

    private static func floorMetrics(for bounds: StepBounds) -> (largest: CGFloat, halfExtent: CGFloat, y: CGFloat) {
        let largest = max(bounds.largestDimension, 10)
        return (
            largest: CGFloat(largest),
            halfExtent: CGFloat(largest * 0.65),
            y: -CGFloat(max(bounds.height, 0.1)) / 2
        )
    }

    private static func addShadowFloor(to scene: SCNScene, bounds: StepBounds, isDarkMode: Bool) {
        let metrics = floorMetrics(for: bounds)
        let floor = SCNPlane(width: metrics.halfExtent * 2, height: metrics.halfExtent * 2)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = isDarkMode
            ? PlatformColor.white.withAlphaComponent(0.045)
            : PlatformColor.black.withAlphaComponent(0.025)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        material.transparencyMode = .aOne
        material.writesToDepthBuffer = true
        material.isDoubleSided = true
        floor.firstMaterial = material

        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "Shadow floor"
        floorNode.position = SCNVector3(0, metrics.y - max(metrics.largest * 0.0008, 0.001), 0)
        floorNode.eulerAngles.x = -SceneKitScalar.pi / 2
        floorNode.castsShadow = false
        scene.rootNode.addChildNode(floorNode)
    }

    private static func addGrid(to scene: SCNScene, bounds: StepBounds) {
        let metrics = floorMetrics(for: bounds)
        let gridStep = CGFloat(niceGridStep(for: Float(metrics.largest)))
        let lineCount = min(max(Int(ceil(metrics.halfExtent / gridStep)), 2), 80)
        var vertices = [SCNVector3]()
        var indices = [UInt32]()

        for line in -lineCount...lineCount {
            let offset = CGFloat(line) * gridStep
            let indexBase = UInt32(vertices.count)
            vertices.append(SCNVector3(-metrics.halfExtent, metrics.y, offset))
            vertices.append(SCNVector3(metrics.halfExtent, metrics.y, offset))
            vertices.append(SCNVector3(offset, metrics.y, -metrics.halfExtent))
            vertices.append(SCNVector3(offset, metrics.y, metrics.halfExtent))
            indices.append(contentsOf: [indexBase, indexBase + 1, indexBase + 2, indexBase + 3])
        }

        let source = SCNGeometrySource(vertices: vertices)
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = PlatformColor.stairsGrid
        material.lightingModel = .constant
        geometry.firstMaterial = material
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    }

    private static func niceGridStep(for extent: Float) -> Float {
        let roughStep = max(extent / 12, 0.1)
        let exponent = floor(log10(roughStep))
        let base = pow(10, exponent)
        let fraction = roughStep / base

        if fraction < 2 {
            return base
        }
        if fraction < 5 {
            return base * 2
        }
        return base * 5
    }

    private static func addAxes(to scene: SCNScene, bounds: StepBounds) {
        let length = CGFloat(max(bounds.largestDimension * 0.28, 5))
        let radius = max(length * 0.008, 0.025)
        let axes: [(end: SCNVector3, color: PlatformColor)] = [
            (SCNVector3(length, 0, 0), PlatformColor(red: 0.95, green: 0.20, blue: 0.16, alpha: 1)),
            (SCNVector3(0, length, 0), PlatformColor(red: 0.20, green: 0.78, blue: 0.30, alpha: 1)),
            (SCNVector3(0, 0, length), PlatformColor(red: 0.22, green: 0.48, blue: 1.00, alpha: 1))
        ]

        for axis in axes {
            guard let node = cylinder(from: SCNVector3(0, 0, 0), to: axis.end, radius: radius, color: axis.color) else {
                continue
            }
            scene.rootNode.addChildNode(node)
        }
    }

    private static func addLighting(
        to scene: SCNScene,
        bounds: StepBounds,
        isDarkMode: Bool,
        usesColoredAccentLights: Bool
    ) {
        let largest = CGFloat(max(bounds.largestDimension, 10))
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = isDarkMode ? 220 : 420
        ambient.color = PlatformColor(white: 1.0, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        addDirectionalLight(
            to: scene,
            name: "Key light",
            color: PlatformColor(red: 1.0, green: 0.94, blue: 0.82, alpha: 1.0),
            intensity: isDarkMode ? 760 : 980,
            position: SCNVector3(-largest * 0.75, largest * 1.20, largest * 0.95),
            castsShadow: true
        )
        addDirectionalLight(
            to: scene,
            name: "Fill light",
            color: PlatformColor(red: 0.76, green: 0.86, blue: 1.0, alpha: 1.0),
            intensity: isDarkMode ? 320 : 500,
            position: SCNVector3(largest * 0.95, largest * 0.60, -largest * 0.70),
            castsShadow: false
        )

        guard usesColoredAccentLights else {
            return
        }

        addOmniLight(
            to: scene,
            name: "Left blue accent light",
            color: PlatformColor(red: 0.30, green: 0.52, blue: 1.0, alpha: 1.0),
            intensity: isDarkMode ? 260 : 180,
            position: SCNVector3(-largest * 1.10, largest * 0.35, largest * 0.35),
            attenuationEndDistance: largest * 3.0
        )
        addOmniLight(
            to: scene,
            name: "Right red accent light",
            color: PlatformColor(red: 1.0, green: 0.34, blue: 0.28, alpha: 1.0),
            intensity: isDarkMode ? 220 : 150,
            position: SCNVector3(largest * 1.10, largest * 0.35, largest * 0.35),
            attenuationEndDistance: largest * 3.0
        )
    }

    private static func addDirectionalLight(
        to scene: SCNScene,
        name: String,
        color: PlatformColor,
        intensity: CGFloat,
        position: SCNVector3,
        castsShadow: Bool
    ) {
        let light = SCNLight()
        light.type = .directional
        light.color = color
        light.intensity = intensity
        light.castsShadow = castsShadow
        light.shadowMode = .deferred
        light.shadowRadius = 6
        light.shadowSampleCount = 24
        light.shadowColor = PlatformColor.black.withAlphaComponent(0.16)

        let node = SCNNode()
        node.name = name
        node.light = light
        node.position = position
        node.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(node)
    }

    private static func addOmniLight(
        to scene: SCNScene,
        name: String,
        color: PlatformColor,
        intensity: CGFloat,
        position: SCNVector3,
        attenuationEndDistance: CGFloat
    ) {
        let light = SCNLight()
        light.type = .omni
        light.color = color
        light.intensity = intensity
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = attenuationEndDistance
        light.attenuationFalloffExponent = 2
        light.castsShadow = false

        let node = SCNNode()
        node.name = name
        node.light = light
        node.position = position
        scene.rootNode.addChildNode(node)
    }

    private static func addCamera(to scene: SCNScene, bounds: StepBounds) -> SCNNode {
        let largest = CGFloat(max(bounds.largestDimension, 10))
        let distanceMultiplier: CGFloat = 1.25
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = Double(max(largest * 50, 1_000))
        camera.fieldOfView = 48

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            largest * 0.80 * distanceMultiplier,
            largest * 0.62 * distanceMultiplier,
            largest * 1.15 * distanceMultiplier
        )
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        return cameraNode
    }

    private static func cylinder(
        from start: SCNVector3,
        to end: SCNVector3,
        radius: CGFloat,
        color: PlatformColor
    ) -> SCNNode? {
        let vector = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
        let length = vectorLength(vector)
        guard length > 0 else {
            return nil
        }

        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.12)
        cylinder.firstMaterial = material

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )
        orientCylinder(node, along: vector)
        return node
    }

    private static func orientCylinder(_ node: SCNNode, along vector: SCNVector3) {
        let length = vectorLength(vector)
        guard length > 0 else {
            return
        }

        let direction = SCNVector3(vector.x / length, vector.y / length, vector.z / length)
        let yAxis = SCNVector3(0, 1, 0)
        let axis = cross(yAxis, direction)
        let axisLength = vectorLength(axis)
        let angle = acos(max(-1, min(1, dot(yAxis, direction))))

        if axisLength < 0.0001 {
            if direction.y < 0 {
                node.rotation = SCNVector4(1, 0, 0, SceneKitScalar.pi)
            }
            return
        }

        node.rotation = SCNVector4(
            axis.x / axisLength,
            axis.y / axisLength,
            axis.z / axisLength,
            angle
        )
    }

    private static func vectorLength(_ vector: SCNVector3) -> SceneKitScalar {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }

    private static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SceneKitScalar {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}
