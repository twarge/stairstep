#if os(visionOS)
import RealityKit
import StairsCore
import SwiftUI

/// Hands tessellated meshes to the volumetric window. A window value has to be
/// small and codable, so the volume is opened with the model's id and looks the
/// mesh up here.
@MainActor
enum StepModelVolumeStore {
    static let windowID = "model-volume"
    private static var meshes = [UUID: StepTriangleMesh]()

    static func register(_ mesh: StepTriangleMesh, for id: UUID) {
        meshes[id] = mesh
    }

    static func mesh(for id: UUID) -> StepTriangleMesh? {
        meshes[id]
    }

    static func remove(_ id: UUID) {
        meshes[id] = nil
    }
}

/// The open model as a RealityKit entity in a volume, scaled to fit.
struct StepModelVolumeView: View {
    var modelID: UUID?

    /// Volume edge in metres, and how much of it the model's longest side fills.
    static let edge: CGFloat = 0.6
    private static let fill: Float = 0.8

    var body: some View {
        if let modelID, let mesh = StepModelVolumeStore.mesh(for: modelID) {
            RealityView { content in
                if let entity = Self.makeEntity(mesh: mesh) {
                    content.add(entity)
                }
            }
            .onDisappear {
                StepModelVolumeStore.remove(modelID)
            }
        } else {
            // A volume restored after relaunch has no mesh to show.
            ContentUnavailableView("Model Unavailable", systemImage: "cube.transparent")
        }
    }

    private static func makeEntity(mesh: StepTriangleMesh) -> ModelEntity? {
        let (descriptors, colors) = RealityStepMeshBuilder.parts(for: mesh, usesOriginalColors: true)
        guard !descriptors.isEmpty,
              let resource = try? MeshResource.generate(from: descriptors) else {
            return nil
        }

        let materials = colors.map { color -> any RealityKit.Material in
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.roughness = 0.42
            material.metallic = 0.0
            material.faceCulling = .none
            return material
        }

        let entity = ModelEntity(mesh: resource, materials: materials)
        entity.name = "STEP mesh"
        // The builder recentres the mesh; model units are millimetres.
        let largest = max(mesh.bounds.largestDimension, .leastNonzeroMagnitude)
        entity.scale = SIMD3(repeating: Float(edge) * fill / largest)
        return entity
    }
}
#endif
