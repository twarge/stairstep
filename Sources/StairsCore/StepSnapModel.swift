import Foundation
import simd

/// Precomputed geometry for snapping a cursor to a model's real vertices, edges,
/// and faces. Built once per model, off the main actor.
///
/// Real edges are distinguished from interior tessellation edges using the
/// per-triangle OpenCascade face id (`StepMeshVertex.faceId`): an edge is a
/// feature edge when it borders two different faces or lies on the mesh boundary.
/// "Faces" are simply the triangles sharing a face id, and snap vertices are the
/// endpoints of feature edges (i.e. real corners). All geometry is stored in
/// world space (mesh position minus the model center), matching the rendered scene.
public final class StepSnapModel: @unchecked Sendable {
    public let largestDimension: Float

    private let vertexPoints: [SIMD3<Float>]
    private let edgeSegments: [StepLineSegment]
    private let triangleFaceIds: [UInt32]
    private let triangleCentroids: [SIMD3<Float>]
    private let faceTriangleVertices: [UInt32: [SIMD3<Float>]]
    // Unit world-space normals of faces that are planar (all their triangles
    // share a normal). Absent for curved faces.
    private let facePlaneNormals: [UInt32: SIMD3<Float>]

    private let cellSize: Float
    private let vertexCells: [Cell: [Int]]
    private let edgeCells: [Cell: [Int]]
    private let triangleCells: [Cell: [Int]]

    private struct Cell: Hashable {
        var x: Int32
        var y: Int32
        var z: Int32
    }

    public init?(mesh: StepTriangleMesh, center: SIMD3<Float>) {
        let indices = mesh.indices
        let meshVertices = mesh.vertices
        guard indices.count >= 3 else { return nil }

        let largest = max(mesh.bounds.largestDimension, 1e-4)
        largestDimension = largest
        let weldTolerance = max(largest * 1e-5, 1e-7)
        let inverseWeld = 1 / weldTolerance

        // Weld coincident positions (across faces) into shared indices.
        var uniquePositions = [SIMD3<Float>]()
        var indexForKey = [WeldKey: Int]()
        func weld(_ meshIndex: Int) -> Int {
            let world = meshVertices[meshIndex].position - center
            let key = WeldKey(
                x: Int64((world.x * inverseWeld).rounded()),
                y: Int64((world.y * inverseWeld).rounded()),
                z: Int64((world.z * inverseWeld).rounded())
            )
            if let existing = indexForKey[key] {
                return existing
            }
            let index = uniquePositions.count
            uniquePositions.append(world)
            indexForKey[key] = index
            return index
        }

        var triangleVertexIndices = [(Int, Int, Int)]()
        var triangleFaceIds = [UInt32]()
        var triangle = 0
        while triangle + 2 < indices.count {
            defer { triangle += 3 }
            let i0 = Int(indices[triangle])
            let i1 = Int(indices[triangle + 1])
            let i2 = Int(indices[triangle + 2])
            guard i0 < meshVertices.count, i1 < meshVertices.count, i2 < meshVertices.count else {
                continue
            }
            let a = weld(i0), b = weld(i1), c = weld(i2)
            guard a != b, b != c, a != c else {
                continue
            }
            triangleVertexIndices.append((a, b, c))
            triangleFaceIds.append(meshVertices[i0].faceId)
        }

        let triangleCount = triangleVertexIndices.count
        guard triangleCount > 0 else {
            return nil
        }
        self.triangleFaceIds = triangleFaceIds

        // Map each undirected edge to the face ids of its incident triangles.
        var facesForEdge = [EdgeKey: [UInt32]]()
        facesForEdge.reserveCapacity(triangleCount * 2)
        for index in 0..<triangleCount {
            let (a, b, c) = triangleVertexIndices[index]
            let faceId = triangleFaceIds[index]
            facesForEdge[EdgeKey(a, b), default: []].append(faceId)
            facesForEdge[EdgeKey(b, c), default: []].append(faceId)
            facesForEdge[EdgeKey(c, a), default: []].append(faceId)
        }

        // A feature edge borders two different faces, or lies on the boundary.
        var edgeSegments = [StepLineSegment]()
        var featureVertexSet = Set<Int>()
        for (edge, faces) in facesForEdge {
            let isFeature = faces.count == 1 || Set(faces).count >= 2
            guard isFeature else { continue }
            edgeSegments.append(StepLineSegment(start: uniquePositions[edge.a], end: uniquePositions[edge.b]))
            featureVertexSet.insert(edge.a)
            featureVertexSet.insert(edge.b)
        }
        self.edgeSegments = edgeSegments
        vertexPoints = featureVertexSet.map { uniquePositions[$0] }

        var centroids = [SIMD3<Float>]()
        centroids.reserveCapacity(triangleCount)
        var faceTriangleVertices = [UInt32: [SIMD3<Float>]]()
        var triangleNormals = [SIMD3<Float>]()
        triangleNormals.reserveCapacity(triangleCount)
        var faceNormalSum = [UInt32: SIMD3<Float>]()
        for index in 0..<triangleCount {
            let (a, b, c) = triangleVertexIndices[index]
            let pa = uniquePositions[a], pb = uniquePositions[b], pc = uniquePositions[c]
            centroids.append((pa + pb + pc) / 3)
            let faceId = triangleFaceIds[index]
            faceTriangleVertices[faceId, default: []].append(contentsOf: [pa, pb, pc])
            let normal = triangleNormal(pa, pb, pc)
            triangleNormals.append(normal)
            faceNormalSum[faceId, default: .zero] += normal
        }
        triangleCentroids = centroids
        self.faceTriangleVertices = faceTriangleVertices

        // A face is planar when every one of its triangles points the same way as
        // the face's average normal. Record the plane normal for planar faces so
        // two of them can be measured normal-to-normal.
        var averageNormals = [UInt32: SIMD3<Float>]()
        for (faceId, sum) in faceNormalSum where simd_length(sum) > 0 {
            averageNormals[faceId] = simd_normalize(sum)
        }
        var nonPlanarFaces = Set<UInt32>()
        let planarCosine: Float = 0.9998 // ~1.1°
        for index in 0..<triangleCount {
            let faceId = triangleFaceIds[index]
            if let average = averageNormals[faceId], simd_dot(triangleNormals[index], average) < planarCosine {
                nonPlanarFaces.insert(faceId)
            }
        }
        facePlaneNormals = averageNormals.filter { !nonPlanarFaces.contains($0.key) }

        // Spatial grids. Feature edges are bucketed along their length so long
        // face edges (a planar face may tessellate to a single edge) are found
        // near any point along them.
        let cell = max(largest / 24, weldTolerance * 4)
        cellSize = cell

        func cellOf(_ p: SIMD3<Float>) -> Cell {
            Cell(
                x: Int32((p.x / cell).rounded(.down).clampedToInt32),
                y: Int32((p.y / cell).rounded(.down).clampedToInt32),
                z: Int32((p.z / cell).rounded(.down).clampedToInt32)
            )
        }

        var vertexCells = [Cell: [Int]]()
        for (index, point) in vertexPoints.enumerated() {
            vertexCells[cellOf(point), default: []].append(index)
        }
        self.vertexCells = vertexCells

        var edgeCells = [Cell: [Int]]()
        for (index, segment) in edgeSegments.enumerated() {
            let length = simd_distance(segment.start, segment.end)
            let steps = max(Int((length / cell).rounded(.up)), 1)
            var seen = Set<Cell>()
            for step in 0...steps {
                let t = Float(step) / Float(steps)
                let key = cellOf(lerp3(segment.start, segment.end, t))
                if seen.insert(key).inserted {
                    edgeCells[key, default: []].append(index)
                }
            }
        }
        self.edgeCells = edgeCells

        var triangleCells = [Cell: [Int]]()
        for (index, centroid) in centroids.enumerated() {
            triangleCells[cellOf(centroid), default: []].append(index)
        }
        self.triangleCells = triangleCells
    }

    /// A world-space radius suitable for gathering snap candidates near a hit
    /// point before screen-space filtering.
    public var queryRadius: Float {
        largestDimension * 0.08
    }

    public var featureVertexCount: Int { vertexPoints.count }
    public var featureEdgeCount: Int { edgeSegments.count }

    public func featureVertices(near point: SIMD3<Float>, radius: Float) -> [SIMD3<Float>] {
        gather(vertexCells, near: point, radius: radius).map { vertexPoints[$0] }
    }

    public func featureEdges(near point: SIMD3<Float>, radius: Float) -> [StepLineSegment] {
        gather(edgeCells, near: point, radius: radius).map { edgeSegments[$0] }
    }

    /// Face id of the triangle nearest `point`, for highlighting a whole face.
    /// Uses a wide radius: a flat face may tessellate to only a couple of large
    /// triangles whose centroids are far from a hit near the face's edge.
    public func faceRegion(near point: SIMD3<Float>) -> Int? {
        var best: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for index in gather(triangleCells, near: point, radius: largestDimension * 0.6) {
            let d = simd_distance_squared(triangleCentroids[index], point)
            if d < bestDistance {
                bestDistance = d
                best = Int(triangleFaceIds[index])
            }
        }
        return best
    }

    /// Flat triangle-vertex triples (world space) for the given face region.
    public func regionTriangleVertices(_ region: Int) -> [SIMD3<Float>] {
        faceTriangleVertices[UInt32(region)] ?? []
    }

    /// Unit world-space normal of the face at `region`, if that face is planar.
    public func facePlaneNormal(region: Int) -> SIMD3<Float>? {
        facePlaneNormals[UInt32(region)]
    }

    private func gather(_ grid: [Cell: [Int]], near point: SIMD3<Float>, radius: Float) -> [Int] {
        let span = Int32((radius / cellSize).rounded(.up).clampedToInt32)
        let base = Cell(
            x: Int32((point.x / cellSize).rounded(.down).clampedToInt32),
            y: Int32((point.y / cellSize).rounded(.down).clampedToInt32),
            z: Int32((point.z / cellSize).rounded(.down).clampedToInt32)
        )
        var result = [Int]()
        var dx = -span
        while dx <= span {
            var dy = -span
            while dy <= span {
                var dz = -span
                while dz <= span {
                    if let items = grid[Cell(x: base.x + dx, y: base.y + dy, z: base.z + dz)] {
                        result.append(contentsOf: items)
                    }
                    dz += 1
                }
                dy += 1
            }
            dx += 1
        }
        return result
    }

    private struct WeldKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }

    private struct EdgeKey: Hashable {
        var a: Int
        var b: Int
        init(_ x: Int, _ y: Int) {
            if x < y {
                a = x
                b = y
            } else {
                a = y
                b = x
            }
        }
    }
}

private func lerp3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}

private func triangleNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
    let normal = simd_cross(b - a, c - a)
    let length = simd_length(normal)
    return length > 0 ? normal / length : SIMD3<Float>(0, 1, 0)
}

private extension Float {
    /// Clamps to the Int32 range so an out-of-range coordinate can't trap.
    var clampedToInt32: Float {
        Swift.min(Swift.max(self, -2_000_000_000), 2_000_000_000)
    }
}
