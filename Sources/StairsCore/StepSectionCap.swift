import Foundation
import simd

/// A triangulated cap that fills the exposed face of a cross-section so the cut
/// reads as solid material. Positions are in the model's own space (the same
/// space as ``StepTriangleMesh`` vertices), ready to hang under the centered
/// model node.
public struct StepSectionCapMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normal: SIMD3<Float>
    public var indices: [UInt32]
    /// The cut outline, as closed loops in model space (no cap lift applied, so
    /// these are the true geometric positions). Used to snap measurements to the
    /// cross-section's own edges and corners.
    public var loops: [[SIMD3<Float>]] = []

    public var isEmpty: Bool {
        indices.isEmpty
    }
}

/// Builds a solid cap for a cross-section by intersecting the mesh with the
/// section plane on the CPU.
///
/// The pipeline is: slice every triangle against the plane to get boundary
/// segments, stitch the segments into closed loops, then triangulate the loops
/// (handling interior holes) in the plane's 2D space. It is intentionally
/// defensive — any step that cannot be completed cleanly is skipped, and a
/// `nil`/empty result simply means the caller shows the open cut instead of a
/// solid one. All work is pure and `Sendable`, so it can run off the main actor.
public enum StepSectionCapBuilder {
    /// Upper bound on boundary segments before the cap is abandoned, to keep an
    /// interactive drag responsive on very dense meshes.
    private static let maxSegments = 200_000

    /// How far to float the cap in front of the cut, as a fraction of the model's
    /// largest dimension, to avoid z-fighting with the clipped mesh boundary.
    /// Small enough to read as a thin cap, large enough to win the depth test.
    private static let capForwardLiftFraction: Float = 0.006

    public static func build(mesh: StepTriangleMesh, plane: StepSectionPlane) -> StepSectionCapMesh? {
        let axis = plane.axis.index
        let (uAxis, vAxis) = inPlaneAxes(for: axis)
        let offset = plane.offset

        let tolerance = max(mesh.bounds.largestDimension * 1e-4, 1e-6)

        var segments = [Segment]()
        segments.reserveCapacity(1024)

        let vertices = mesh.vertices
        let indices = mesh.indices
        var triangle = 0
        while triangle + 2 < indices.count {
            defer { triangle += 3 }
            let i0 = Int(indices[triangle])
            let i1 = Int(indices[triangle + 1])
            let i2 = Int(indices[triangle + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else {
                continue
            }
            let p0 = vertices[i0].position
            let p1 = vertices[i1].position
            let p2 = vertices[i2].position
            guard let segment = sliceTriangle(
                p0, p1, p2,
                axis: axis, uAxis: uAxis, vAxis: vAxis, offset: offset
            ) else {
                continue
            }
            segments.append(segment)
            if segments.count > maxSegments {
                return nil
            }
        }

        guard segments.count >= 3 else {
            return nil
        }

        let loops = assembleLoops(from: segments, tolerance: tolerance)
        guard !loops.isEmpty else {
            return nil
        }

        let triangulator = LoopTriangulator(loops: loops)
        let triangles = triangulator.triangulate()
        guard !triangles.points.isEmpty, !triangles.indices.isEmpty else {
            return nil
        }

        let normal = plane.cutNormal
        // Float the cap a hair toward the removed side (the viewer's side) so it
        // wins the depth test against the mesh's cut-boundary triangles, which the
        // clip shader keeps right up to the same plane. Without this lift the cap
        // and those triangles are coplanar and z-fight.
        let lift = normal * (mesh.bounds.largestDimension * capForwardLiftFraction)
        let positions = triangles.points.map { point in
            reconstruct(u: point.x, v: point.y, offset: offset, axis: axis, uAxis: uAxis, vAxis: vAxis) + lift
        }

        let boundaryLoops = loops.map { loop in
            loop.map { reconstruct(u: $0.x, v: $0.y, offset: offset, axis: axis, uAxis: uAxis, vAxis: vAxis) }
        }
        return StepSectionCapMesh(
            positions: positions,
            normal: normal,
            indices: triangles.indices,
            loops: boundaryLoops
        )
    }

    // MARK: - Plane axis mapping

    /// The two in-plane axes (u, v) for a section perpendicular to `axis`, chosen
    /// so (u, v, axis) stays a consistent right-handed frame.
    private static func inPlaneAxes(for axis: Int) -> (u: Int, v: Int) {
        switch axis {
        case 0: (1, 2) // X plane: u = Y, v = Z
        case 1: (2, 0) // Y plane: u = Z, v = X
        default: (0, 1) // Z plane: u = X, v = Y
        }
    }

    private static func reconstruct(
        u: Float, v: Float, offset: Float,
        axis: Int, uAxis: Int, vAxis: Int
    ) -> SIMD3<Float> {
        var position = SIMD3<Float>(repeating: 0)
        position[axis] = offset
        position[uAxis] = u
        position[vAxis] = v
        return position
    }

    // MARK: - Triangle slicing

    private struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
    }

    /// Returns the line segment where a triangle crosses the plane, in (u, v)
    /// coordinates, or `nil` when the triangle does not straddle the plane.
    private static func sliceTriangle(
        _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>,
        axis: Int, uAxis: Int, vAxis: Int, offset: Float
    ) -> Segment? {
        let s0 = p0[axis] - offset
        let s1 = p1[axis] - offset
        let s2 = p2[axis] - offset

        var crossings = [SIMD2<Float>]()
        crossings.reserveCapacity(2)
        appendCrossing(p0, p1, s0, s1, uAxis: uAxis, vAxis: vAxis, into: &crossings)
        appendCrossing(p1, p2, s1, s2, uAxis: uAxis, vAxis: vAxis, into: &crossings)
        appendCrossing(p2, p0, s2, s0, uAxis: uAxis, vAxis: vAxis, into: &crossings)

        guard crossings.count == 2 else {
            return nil
        }
        let a = crossings[0]
        let b = crossings[1]
        if simd_distance(a, b) <= 0 {
            return nil
        }
        return Segment(a: a, b: b)
    }

    /// Adds the plane crossing on edge (pa, pb) to `crossings` when the edge
    /// straddles the plane. A half-open sign test (`< 0` vs `>= 0`) makes a
    /// vertex that lies exactly on the plane belong to one side only, so a shared
    /// edge is not double-counted.
    private static func appendCrossing(
        _ pa: SIMD3<Float>, _ pb: SIMD3<Float>,
        _ sa: Float, _ sb: Float,
        uAxis: Int, vAxis: Int,
        into crossings: inout [SIMD2<Float>]
    ) {
        let negativeA = sa < 0
        let negativeB = sb < 0
        guard negativeA != negativeB else {
            return
        }
        let denominator = sa - sb
        guard denominator != 0 else {
            return
        }
        let t = sa / denominator
        let point = pa + (pb - pa) * t
        crossings.append(SIMD2<Float>(point[uAxis], point[vAxis]))
    }

    // MARK: - Loop assembly

    /// Stitches unordered boundary segments into closed loops by matching shared
    /// endpoints (quantized to `tolerance`). Assumes the slice is manifold, i.e.
    /// each boundary vertex joins exactly two segments; non-manifold junctions
    /// are walked best-effort.
    private static func assembleLoops(from segments: [Segment], tolerance: Float) -> [[SIMD2<Float>]] {
        let inverseTolerance = 1 / max(tolerance, .leastNormalMagnitude)

        var pointForKey = [PointKey: Int]()
        var points = [SIMD2<Float>]()
        points.reserveCapacity(segments.count)

        func identify(_ point: SIMD2<Float>) -> Int {
            let key = PointKey(
                u: Int64((point.x * inverseTolerance).rounded()),
                v: Int64((point.y * inverseTolerance).rounded())
            )
            if let existing = pointForKey[key] {
                return existing
            }
            let index = points.count
            points.append(point)
            pointForKey[key] = index
            return index
        }

        // Adjacency as pairs of neighbor endpoints, tracked by undirected edge id.
        var adjacency = [[Int]]()
        var edgeEndpoints = [(Int, Int)]()
        var edgesForPoint = [[Int]]()

        func ensureCapacity(_ index: Int) {
            while adjacency.count <= index {
                adjacency.append([])
                edgesForPoint.append([])
            }
        }

        for segment in segments {
            let a = identify(segment.a)
            let b = identify(segment.b)
            if a == b {
                continue
            }
            ensureCapacity(max(a, b))
            let edgeID = edgeEndpoints.count
            edgeEndpoints.append((a, b))
            adjacency[a].append(b)
            adjacency[b].append(a)
            edgesForPoint[a].append(edgeID)
            edgesForPoint[b].append(edgeID)
        }

        var usedEdge = [Bool](repeating: false, count: edgeEndpoints.count)

        func firstUnusedEdge(at point: Int) -> Int? {
            guard point < edgesForPoint.count else {
                return nil
            }
            return edgesForPoint[point].first { !usedEdge[$0] }
        }

        var loops = [[SIMD2<Float>]]()

        for startPoint in points.indices {
            while let startEdge = firstUnusedEdge(at: startPoint) {
                // Seed with the start vertex: the walk below only appends the far
                // end of each edge it crosses, so without this the loop would come
                // back around and close over the start vertex, silently dropping it
                // and cutting the corner there off with a chord.
                var loopIndices = [startPoint]
                var currentPoint = startPoint
                var currentEdge = startEdge

                while true {
                    usedEdge[currentEdge] = true
                    let (endA, endB) = edgeEndpoints[currentEdge]
                    let nextPoint = endA == currentPoint ? endB : endA
                    loopIndices.append(nextPoint)

                    if nextPoint == startPoint {
                        break
                    }
                    guard let nextEdge = firstUnusedEdge(at: nextPoint) else {
                        break // dead end: open polyline, discard below
                    }
                    currentPoint = nextPoint
                    currentEdge = nextEdge
                }

                if loopIndices.count >= 3, loopIndices.last == startPoint {
                    loopIndices.removeLast() // drop the closing duplicate
                    loops.append(loopIndices.map { points[$0] })
                }
            }
        }

        return loops.filter { $0.count >= 3 }
    }

    private struct PointKey: Hashable {
        var u: Int64
        var v: Int64
    }
}
