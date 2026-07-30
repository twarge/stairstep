import Foundation
import simd

/// Formats a loaded model can be written out as.
///
/// These are all *mesh* formats, written from the tessellated triangles the
/// importer already produced. STEP and IGES are deliberately absent: writing them
/// back out needs the original B-rep, which the pipeline discards once it has
/// tessellated, so a "STEP export" here would really be a mesh wearing a `.step`
/// extension.
public enum StepExportFormat: String, CaseIterable, Sendable, Identifiable {
    case stl
    case obj
    case ply
    case glb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stl: "STL"
        case .obj: "OBJ"
        case .ply: "PLY"
        case .glb: "glTF Binary"
        }
    }

    public var fileExtension: String { rawValue }

    /// Uniform type identifier, matching the ones this app already declares for
    /// reading these formats.
    public var contentTypeIdentifier: String {
        switch self {
        case .stl: "com.twarge.stairs.stl"
        case .obj: "com.twarge.stairs.obj"
        case .ply: "com.twarge.stairs.ply"
        case .glb: "com.twarge.stairs.glb"
        }
    }

    /// Whether the payload is human-readable, so the clipboard can also carry it
    /// as plain text.
    public var isText: Bool {
        switch self {
        case .obj, .ply: true
        case .stl, .glb: false
        }
    }
}

public enum StepExportError: LocalizedError {
    case emptyMesh

    public var errorDescription: String? {
        switch self {
        case .emptyMesh:
            "This model has no triangles to export."
        }
    }
}

/// Writes a tessellated mesh out in the interchange formats above.
public enum StepMeshExporter {
    public static func data(
        for mesh: StepTriangleMesh,
        format: StepExportFormat,
        modelName: String = "model"
    ) throws -> Data {
        guard mesh.indices.count >= 3, !mesh.vertices.isEmpty else {
            throw StepExportError.emptyMesh
        }
        switch format {
        case .stl: return stlData(mesh)
        case .obj: return objData(mesh, modelName: modelName)
        case .ply: return plyData(mesh)
        case .glb: return glbData(mesh, modelName: modelName)
        }
    }

    // MARK: - STL (binary)

    /// 80-byte header, triangle count, then 50 bytes per triangle. Binary rather
    /// than ASCII: a tessellated CAD model runs to hundreds of thousands of
    /// triangles, where the ASCII form is roughly five times the size.
    private static func stlData(_ mesh: StepTriangleMesh) -> Data {
        let triangleCount = mesh.indices.count / 3
        var data = Data(count: 80) // header: conventionally zeroed, never "solid"
        data.reserveCapacity(84 + triangleCount * 50)
        append(UInt32(triangleCount), to: &data)

        forEachTriangle(mesh) { a, b, c in
            let normal = faceNormal(a, b, c)
            append(normal, to: &data)
            append(a, to: &data)
            append(b, to: &data)
            append(c, to: &data)
            append(UInt16(0), to: &data) // attribute byte count
        }
        return data
    }

    // MARK: - OBJ

    private static func objData(_ mesh: StepTriangleMesh, modelName: String) -> Data {
        var text = "# Exported by Stairstep\no \(sanitized(modelName))\n"
        text.reserveCapacity(mesh.vertices.count * 48 + mesh.indices.count * 12)

        for vertex in mesh.vertices {
            text += "v \(number(vertex.position.x)) \(number(vertex.position.y)) \(number(vertex.position.z))\n"
        }
        for vertex in mesh.vertices {
            text += "vn \(number(vertex.normal.x)) \(number(vertex.normal.y)) \(number(vertex.normal.z))\n"
        }
        // OBJ indices are 1-based, and `v//vn` pairs the position with its normal.
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            let i = mesh.indices[triangle] + 1
            let j = mesh.indices[triangle + 1] + 1
            let k = mesh.indices[triangle + 2] + 1
            text += "f \(i)//\(i) \(j)//\(j) \(k)//\(k)\n"
            triangle += 3
        }
        return Data(text.utf8)
    }

    // MARK: - PLY (ASCII)

    private static func plyData(_ mesh: StepTriangleMesh) -> Data {
        var text = """
        ply
        format ascii 1.0
        comment Exported by Stairstep
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(mesh.indices.count / 3)
        property list uchar int vertex_indices
        end_header

        """
        text.reserveCapacity(mesh.vertices.count * 64 + mesh.indices.count * 10)

        for vertex in mesh.vertices {
            text += "\(number(vertex.position.x)) \(number(vertex.position.y)) \(number(vertex.position.z))"
            text += " \(number(vertex.normal.x)) \(number(vertex.normal.y)) \(number(vertex.normal.z))\n"
        }
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            text += "3 \(mesh.indices[triangle]) \(mesh.indices[triangle + 1]) \(mesh.indices[triangle + 2])\n"
            triangle += 3
        }
        return Data(text.utf8)
    }

    // MARK: - glTF binary

    /// A single-node, single-primitive glTF 2.0 file in the GLB container: a
    /// 12-byte header followed by a JSON chunk and a binary chunk, each padded to a
    /// 4-byte boundary.
    private static func glbData(_ mesh: StepTriangleMesh, modelName: String) -> Data {
        let vertexCount = mesh.vertices.count
        let indexCount = mesh.indices.count

        var binary = Data()
        binary.reserveCapacity(vertexCount * 24 + indexCount * 4)
        for vertex in mesh.vertices {
            append(vertex.position, to: &binary)
        }
        let normalsOffset = binary.count
        for vertex in mesh.vertices {
            append(vertex.normal, to: &binary)
        }
        let indicesOffset = binary.count
        for index in mesh.indices {
            append(index, to: &binary)
        }

        // POSITION requires min/max in the accessor; take them from the mesh bounds.
        let bounds = mesh.bounds
        let minimum = [bounds.minX, bounds.minY, bounds.minZ]
        let maximum = [bounds.maxX, bounds.maxY, bounds.maxZ]

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Stairstep"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": sanitized(modelName)]],
            "meshes": [[
                "name": sanitized(modelName),
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1],
                    "indices": 2,
                    "mode": 4, // triangles
                ]],
            ]],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": normalsOffset, "target": 34962],
                ["buffer": 0, "byteOffset": normalsOffset, "byteLength": indicesOffset - normalsOffset, "target": 34962],
                ["buffer": 0, "byteOffset": indicesOffset, "byteLength": binary.count - indicesOffset, "target": 34963],
            ],
            "accessors": [
                [
                    "bufferView": 0, "componentType": 5126, "count": vertexCount,
                    "type": "VEC3", "min": minimum, "max": maximum,
                ],
                ["bufferView": 1, "componentType": 5126, "count": vertexCount, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5125, "count": indexCount, "type": "SCALAR"],
            ],
        ]

        var jsonChunk = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        // The JSON chunk pads with spaces, the binary chunk with zeros.
        while jsonChunk.count % 4 != 0 {
            jsonChunk.append(0x20)
        }
        var binaryChunk = binary
        while binaryChunk.count % 4 != 0 {
            binaryChunk.append(0)
        }

        var data = Data()
        let totalLength = 12 + 8 + jsonChunk.count + 8 + binaryChunk.count
        append(UInt32(0x4674_6C67), to: &data) // "glTF"
        append(UInt32(2), to: &data)
        append(UInt32(totalLength), to: &data)
        append(UInt32(jsonChunk.count), to: &data)
        append(UInt32(0x4E4F_534A), to: &data) // "JSON"
        data.append(jsonChunk)
        append(UInt32(binaryChunk.count), to: &data)
        append(UInt32(0x004E_4942), to: &data) // "BIN\0"
        data.append(binaryChunk)
        return data
    }

    // MARK: - Helpers

    private static func forEachTriangle(
        _ mesh: StepTriangleMesh,
        _ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) -> Void
    ) {
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            defer { triangle += 3 }
            let i = Int(mesh.indices[triangle])
            let j = Int(mesh.indices[triangle + 1])
            let k = Int(mesh.indices[triangle + 2])
            guard i < mesh.vertices.count, j < mesh.vertices.count, k < mesh.vertices.count else {
                continue
            }
            body(mesh.vertices[i].position, mesh.vertices[j].position, mesh.vertices[k].position)
        }
    }

    /// Face normal from the winding, rather than an averaged vertex normal: STL
    /// stores one normal per facet and readers expect it to match the triangle.
    private static func faceNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let normal = simd_cross(b - a, c - a)
        let length = simd_length(normal)
        return length > 0 ? normal / length : SIMD3<Float>(0, 0, 1)
    }

    private static func number(_ value: Float) -> String {
        String(format: "%.6f", value)
    }

    private static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "\n", with: " ")
        return cleaned.isEmpty ? "model" : cleaned
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: Float, to data: inout Data) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: SIMD3<Float>, to data: inout Data) {
        append(value.x, to: &data)
        append(value.y, to: &data)
        append(value.z, to: &data)
    }
}
