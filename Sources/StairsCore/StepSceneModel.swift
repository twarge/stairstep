import Foundation
import simd
import SceneKit

#if canImport(StairsStepImporter)
import StairsStepImporter
#endif

public enum StepCameraProjection: String, Codable, Hashable, Sendable {
    case perspective
    case orthographic

    public var toggled: StepCameraProjection {
        switch self {
        case .perspective: .orthographic
        case .orthographic: .perspective
        }
    }
}

public struct StepSceneCameraState: Codable, Equatable {
    public var transform: [Float]
    public var projection: StepCameraProjection
    public var orthographicScale: Double?

    public init(
        transform: [Float],
        projection: StepCameraProjection = .perspective,
        orthographicScale: Double? = nil
    ) {
        self.transform = transform
        self.projection = projection
        self.orthographicScale = orthographicScale
    }

    public var isValid: Bool {
        transform.count == 16
            && transform.allSatisfy(\.isFinite)
            && (orthographicScale == nil || orthographicScale?.isFinite == true)
    }
}

public struct StepSceneOptions: Hashable, Sendable {
    public var showsAxes: Bool
    public var showsGrid: Bool
    public var showsFloor: Bool
    public var showsWireframe: Bool
    public var usesOriginalColors: Bool
    public var usesColoredAccentLights: Bool

    public init(
        showsAxes: Bool = false,
        showsGrid: Bool = true,
        showsFloor: Bool = false,
        showsWireframe: Bool = false,
        usesOriginalColors: Bool = true,
        usesColoredAccentLights: Bool = true
    ) {
        self.showsAxes = showsAxes
        self.showsGrid = showsGrid
        self.showsFloor = showsFloor
        self.showsWireframe = showsWireframe
        self.usesOriginalColors = usesOriginalColors
        self.usesColoredAccentLights = usesColoredAccentLights
    }
}

public struct StepBounds: Sendable {
    public var minX = Float.greatestFiniteMagnitude
    public var minY = Float.greatestFiniteMagnitude
    public var minZ = Float.greatestFiniteMagnitude
    public var maxX = -Float.greatestFiniteMagnitude
    public var maxY = -Float.greatestFiniteMagnitude
    public var maxZ = -Float.greatestFiniteMagnitude
    public var pointCount = 0

    public var isValid: Bool {
        pointCount > 0
            && minX.isFinite
            && minY.isFinite
            && minZ.isFinite
            && maxX.isFinite
            && maxY.isFinite
            && maxZ.isFinite
    }

    public var width: Float { max(maxX - minX, 0) }
    public var height: Float { max(maxY - minY, 0) }
    public var depth: Float { max(maxZ - minZ, 0) }
    public var largestDimension: Float { max(width, height, depth) }

    public var center: SIMD3<Float> {
        SIMD3<Float>((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
    }

    public var size: SIMD3<Float> {
        SIMD3<Float>(width, height, depth)
    }

    mutating func include(_ point: SIMD3<Float>) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        minZ = min(minZ, point.z)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
        maxZ = max(maxZ, point.z)
        pointCount += 1
    }
}

public struct StepMeshVertex: Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var color: SIMD3<Float>
    /// Index of the originating OpenCascade face (see `HNStepVertex.faceId`).
    /// Lets the snap model tell real face boundaries from tessellation edges.
    public var faceId: UInt32 = 0
}

public struct StepTriangleMesh: Sendable {
    public var vertices: [StepMeshVertex]
    public var indices: [UInt32]
    public var bounds: StepBounds
    public var materialCount: Int

    public var triangleCount: Int {
        indices.count / 3
    }
}

public enum StepImportMode: String, Sendable {
    case openCascadeMesh = "OpenCascade mesh"
    case boundsFallback = "Bounds fallback"
}

public enum StepFileFormat: String, CaseIterable, Sendable {
    case step = "STEP"
    case iges = "IGES"
    case brep = "BREP"
    case stl = "STL"
    case ply = "PLY"
    case obj = "OBJ"
    case glb = "GLB"
    case fcstd = "FreeCAD"

    init?(fileName: String) {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch pathExtension {
        case "step", "stp", "p21":
            self = .step
        case "fcstd":
            self = .fcstd
        case "iges", "igs":
            self = .iges
        case "brep", "rle":
            self = .brep
        case "stl":
            self = .stl
        case "ply":
            self = .ply
        case "obj":
            self = .obj
        case "glb":
            self = .glb
        default:
            return nil
        }
    }

    var temporaryFileExtension: String {
        switch self {
        case .step:
            "step"
        case .iges:
            "igs"
        case .brep:
            "brep"
        case .stl:
            "stl"
        case .ply:
            "ply"
        case .obj:
            "obj"
        case .glb:
            "glb"
        case .fcstd:
            "FCStd"
        }
    }

    /// True when the format is a container this app unpacks itself before handing
    /// geometry to OpenCascade, rather than one OCCT reads directly.
    var isContainerFormat: Bool { self == .fcstd }

    #if canImport(StairsStepImporter)
    var openCascadeRawValue: Int32 {
        switch self {
        case .step:
            0
        case .iges:
            1
        case .brep:
            2
        case .stl:
            3
        case .ply:
            4
        case .obj:
            5
        case .glb:
            6
        case .fcstd:
            // Unpacked in Swift and imported through HNModelImportBReps; it never
            // reaches the path-based reader that consumes this value.
            -1
        }
    }
    #endif
}

public struct StepModel: Identifiable, Sendable {
    public var id = UUID()
    public var fileName: String
    public var byteCount: Int
    public var mesh: StepTriangleMesh?
    public var bounds: StepBounds
    public var importMode: StepImportMode
    public var warnings: [String]

    public var vertexCount: Int {
        mesh?.vertices.count ?? bounds.pointCount
    }

    public var triangleCount: Int {
        mesh?.triangleCount ?? 0
    }

    public var materialCount: Int {
        mesh?.materialCount ?? 1
    }
}

public enum StepImportError: LocalizedError, Sendable {
    case emptyDocument
    case noGeometry
    case openCascadeFailed
    case temporaryFileFailed
    /// The document was understood but none of its drawable content is
    /// reachable — a FreeCAD assembly whose parts all live in other files, say.
    /// Carries the reader's own explanation so the user learns *why*.
    case unreachableContent(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The document is empty."
        case .noGeometry:
            "No 3D geometry could be read from this document."
        case .openCascadeFailed:
            "OpenCascade could not tessellate this STEP file."
        case .temporaryFileFailed:
            "A temporary STEP file could not be prepared for import."
        case .unreachableContent(let reason):
            reason
        }
    }
}

public enum StepMeshImporter {
    /// Loads and tessellates a model. `progress` (optional) reports import
    /// completion as a fraction in `0...1`; it may be called from a background
    /// thread, so the handler must be safe to invoke off the main actor.
    public static func load(
        data: Data,
        fileName: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> StepModel {
        guard !data.isEmpty else {
            throw StepImportError.emptyDocument
        }
        let format = StepFileFormat(fileName: fileName) ?? .step

        #if canImport(StairsStepImporter)
        do {
            return try OpenCascadeStepMeshImporter.load(data: data, fileName: fileName, format: format, progress: progress)
        } catch {
            do {
                return try fallbackModel(
                    data: data,
                    fileName: fileName,
                    warning: "OpenCascade could not import this \(format.rawValue) file; showing parsed extents when possible."
                )
            } catch _ {
                // The import error says what actually went wrong; the fallback
                // failing to find extents adds nothing.
                throw error
            }
        }
        #else
        return try fallbackModel(
            data: data,
            fileName: fileName,
            warning: "Native \(format.rawValue) tessellation is not bundled for this platform; showing parsed extents when possible."
        )
        #endif
    }

    private static func fallbackModel(data: Data, fileName: String, warning: String) throws -> StepModel {
        guard let bounds = StepBoundsParser.bounds(in: data) else {
            throw StepImportError.noGeometry
        }

        return StepModel(
            fileName: fileName,
            byteCount: data.count,
            mesh: nil,
            bounds: bounds,
            importMode: .boundsFallback,
            warnings: [warning]
        )
    }
}

private enum StepBoundsParser {
    static func bounds(in data: Data) -> StepBounds? {
        guard let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"CARTESIAN_POINT\s*\(\s*'[^']*'\s*,\s*\(\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?)\s*\)\s*\)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var bounds = StepBounds()
        expression.enumerateMatches(in: contents, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 4,
                  let xRange = Range(match.range(at: 1), in: contents),
                  let yRange = Range(match.range(at: 2), in: contents),
                  let zRange = Range(match.range(at: 3), in: contents),
                  let x = Float(contents[xRange]),
                  let y = Float(contents[yRange]),
                  let z = Float(contents[zRange]) else {
                return
            }

            bounds.include(StepCoordinateSpace.scenePosition(x: x, y: y, z: z))
        }

        return bounds.isValid ? bounds : nil
    }
}

private enum StepCoordinateSpace {
    static func scenePosition(x: Float, y: Float, z: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, z, -y)
    }

    static func sceneNormal(x: Float, y: Float, z: Float) -> SIMD3<Float> {
        SIMD3<Float>(x, z, -y)
    }
}

#if canImport(StairsStepImporter)
// Relays OCCT progress from the C callback (which passes an opaque context) back
// into a Swift closure. The trampoline is a non-capturing @convention(c) function.
private final class ImportProgressRelay {
    let handler: @Sendable (Double) -> Void
    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }
}

private let importProgressTrampoline: @convention(c) (UnsafeMutableRawPointer?, Double) -> Void = { context, fraction in
    guard let context else { return }
    Unmanaged<ImportProgressRelay>.fromOpaque(context).takeUnretainedValue().handler(fraction)
}

// Sets up (and tears down) the progress context for the duration of `body`. The
// C import runs synchronously, so no callback fires after `body` returns.
private func withImportProgress<T>(
    _ progress: (@Sendable (Double) -> Void)?,
    _ body: (HNProgressCallback?, UnsafeMutableRawPointer?) throws -> T
) rethrows -> T {
    guard let progress else {
        return try body(nil, nil)
    }
    let relay = ImportProgressRelay(progress)
    let context = Unmanaged.passRetained(relay).toOpaque()
    defer { Unmanaged<ImportProgressRelay>.fromOpaque(context).release() }
    return try body(importProgressTrampoline, context)
}

/// One FreeCAD instance readied for the importer: which unique payload it
/// draws, where, and in which colours (a range into a shared colour array).
private struct FCStdImportInstance {
    var payloadIndex: Int
    var placement: FCStdPlacement?
    /// Offset into the shared colour storage, in floats.
    var colorOffset: Int
    /// Number of RGB triples: 1 for a whole-shape colour, N for per-face.
    var colorCount: Int
}

/// Presents FreeCAD instances as the `HNBRepInstance` array the importer takes.
/// Unique payloads are flattened into one allocation so every pointer stays
/// valid for the whole call without nesting an access scope per payload — a
/// document can hold hundreds of shapes, and a link array points many instances
/// at one payload.
private func withFCStdInstances(
    payloads: [Data],
    descriptors: [FCStdImportInstance],
    colorStorage: [Float],
    _ body: (UnsafePointer<HNBRepInstance>, Int) -> Bool
) -> Bool {
    guard !descriptors.isEmpty else {
        return false
    }

    var storage = [UInt8]()
    storage.reserveCapacity(payloads.reduce(0) { $0 + $1.count })
    var offsets = [Int]()
    offsets.reserveCapacity(payloads.count)
    for payload in payloads {
        offsets.append(storage.count)
        storage.append(contentsOf: payload)
    }

    return storage.withUnsafeBytes { rawPayloads -> Bool in
        guard let payloadBase = rawPayloads.baseAddress else {
            return false
        }
        return colorStorage.withUnsafeBufferPointer { colors -> Bool in
            var instances = [HNBRepInstance]()
            instances.reserveCapacity(descriptors.count)
            for descriptor in descriptors {
                var instance = HNBRepInstance()
                instance.bytes = payloadBase.advanced(by: offsets[descriptor.payloadIndex])
                instance.length = payloads[descriptor.payloadIndex].count
                if let placement = descriptor.placement {
                    instance.hasPlacement = true
                    instance.quaternion = (
                        placement.rotation.x,
                        placement.rotation.y,
                        placement.rotation.z,
                        placement.rotation.w
                    )
                    instance.position = (
                        placement.position.x,
                        placement.position.y,
                        placement.position.z
                    )
                }
                if descriptor.colorCount > 0, let colorBase = colors.baseAddress {
                    instance.colors = colorBase.advanced(by: descriptor.colorOffset)
                    instance.colorCount = descriptor.colorCount
                }
                instances.append(instance)
            }
            return instances.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return false
                }
                return body(base, buffer.count)
            }
        }
    }
}

private enum OpenCascadeStepMeshImporter {
    static func load(
        data: Data,
        fileName: String,
        format: StepFileFormat,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> StepModel {
        var importedMesh = HNStepMesh(vertices: nil, vertexCount: 0, indices: nil, indexCount: 0)
        defer {
            HNStepMeshFree(&importedMesh)
        }

        // FreeCAD documents are unpacked here rather than in the importer: the
        // container is a zip whose object graph decides which of its many BREP
        // payloads are drawn where — App::Part groups and App::Link instances
        // place (and repeat) stored shapes, so one payload can back several
        // instances, each with its own transform.
        // BREP carries no colour, so each object's display colour comes from the
        // document's GuiDocument.xml — a whole-shape colour, or per-face
        // DiffuseColor entries — and is attached to its instances on import.
        var freeCADPayloads = [Data]()
        var freeCADDescriptors = [FCStdImportInstance]()
        var freeCADColors = [Float]()
        var freeCADWarnings = [String]()
        if format == .fcstd {
            let document = try FCStdDocument(data: data)
            freeCADWarnings = document.warnings
            if document.hiddenShapeCount > 0 {
                freeCADWarnings.append("\(document.hiddenShapeCount) hidden shape(s) were not drawn.")
            }

            let appearance = FCStdAppearance.colors(in: document.archive)
            let payloadsByEntry = document.payloadsByEntry()
            var payloadIndexByEntry = [String: Int]()
            var colorRangeByObject = [String: (offset: Int, count: Int)]()

            for instance in document.instances {
                // Entries that failed to inflate have no payload; their
                // instances are dropped rather than failing the document.
                guard let payload = payloadsByEntry[instance.entryName] else {
                    continue
                }
                let payloadIndex: Int
                if let existing = payloadIndexByEntry[instance.entryName] {
                    payloadIndex = existing
                } else {
                    payloadIndex = freeCADPayloads.count
                    payloadIndexByEntry[instance.entryName] = payloadIndex
                    freeCADPayloads.append(payload)
                }

                let colorRange: (offset: Int, count: Int)
                if let existing = colorRangeByObject[instance.objectName] {
                    colorRange = existing
                } else {
                    let offset = freeCADColors.count
                    if let faces = appearance.faces[instance.objectName] {
                        for color in faces {
                            freeCADColors.append(contentsOf: [color.x, color.y, color.z])
                        }
                        colorRange = (offset, faces.count)
                    } else {
                        // FreeCAD's own default when a document says nothing.
                        let color = appearance.shape[instance.objectName] ?? SIMD3<Float>(0.8, 0.8, 0.8)
                        freeCADColors.append(contentsOf: [color.x, color.y, color.z])
                        colorRange = (offset, 1)
                    }
                    colorRangeByObject[instance.objectName] = colorRange
                }

                freeCADDescriptors.append(FCStdImportInstance(
                    payloadIndex: payloadIndex,
                    placement: instance.placement,
                    colorOffset: colorRange.offset,
                    colorCount: colorRange.count
                ))
            }
        }

        let imported = try withImportProgress(progress) { callback, context -> Bool in
            if format == .fcstd {
                return withFCStdInstances(
                    payloads: freeCADPayloads,
                    descriptors: freeCADDescriptors,
                    colorStorage: freeCADColors
                ) { instances, count in
                    HNModelImportBReps(instances, count, &importedMesh, callback, context)
                }
            }

            if format == .step {
                // STEP reads directly from the in-memory buffer — no temp file.
                return data.withUnsafeBytes { raw in
                    HNModelImportData(raw.baseAddress, raw.count, &importedMesh, callback, context)
                }
            }

            let temporaryURL = try writeTemporaryModelFile(data: data, format: format)
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            return HNModelImport(temporaryURL.path, format.openCascadeRawValue, &importedMesh, callback, context)
        }

        guard imported else {
            // A FreeCAD document can parse fine yet yield nothing drawable —
            // an assembly whose parts all live in other files. The reader's
            // warnings say so; surface them instead of a generic failure.
            if format == .fcstd, !freeCADWarnings.isEmpty {
                throw StepImportError.unreachableContent(
                    "None of this FreeCAD document's geometry could be drawn. "
                    + freeCADWarnings.joined(separator: " ")
                )
            }
            throw StepImportError.openCascadeFailed
        }

        let vertexCount = Int(importedMesh.vertexCount)
        let indexCount = Int(importedMesh.indexCount)
        guard let importedVertices = importedMesh.vertices,
              let importedIndices = importedMesh.indices,
              vertexCount > 0,
              indexCount >= 3,
              indexCount.isMultiple(of: 3) else {
            throw StepImportError.noGeometry
        }

        let inputVertices = UnsafeBufferPointer(start: importedVertices, count: vertexCount)
        let inputIndices = UnsafeBufferPointer(start: importedIndices, count: indexCount)
        var vertices = [StepMeshVertex]()
        vertices.reserveCapacity(vertexCount)
        var bounds = StepBounds()
        var materialKeys = Set<StepMaterialKey>()

        for vertex in inputVertices {
            let position = StepCoordinateSpace.scenePosition(x: vertex.x, y: vertex.y, z: vertex.z)
            let normal = StepCoordinateSpace.sceneNormal(x: vertex.nx, y: vertex.ny, z: vertex.nz)
            let color = SIMD3<Float>(
                clampedColor(vertex.r),
                clampedColor(vertex.g),
                clampedColor(vertex.b)
            )
            bounds.include(position)
            vertices.append(StepMeshVertex(position: position, normal: normal, color: color, faceId: vertex.faceId))
            materialKeys.insert(StepMaterialKey(color: color))
        }

        guard bounds.isValid else {
            throw StepImportError.noGeometry
        }

        return StepModel(
            fileName: fileName,
            byteCount: data.count,
            mesh: StepTriangleMesh(
                vertices: vertices,
                indices: Array(inputIndices),
                bounds: bounds,
                materialCount: max(materialKeys.count, 1)
            ),
            bounds: bounds,
            importMode: .openCascadeMesh,
            warnings: freeCADWarnings
        )
    }

    private static func writeTemporaryModelFile(data: Data, format: StepFileFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StairsModelImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.temporaryFileExtension)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            throw StepImportError.temporaryFileFailed
        }
    }
}
#endif

private func clampedColor(_ value: Float) -> Float {
    min(max(value, 0), 1)
}
