import Foundation
import simd

/// Triangulates the closed 2D loops produced by slicing a mesh with the section
/// plane, filling outer regions while leaving interior holes empty.
///
/// Nesting is resolved with the even-odd rule (a loop nested an odd number of
/// levels deep is a hole), holes are merged into their containing outer loop by
/// bridging, and each resulting simple polygon is ear-clipped. Every stage fails
/// soft: an un-triangulable loop is dropped rather than aborting the whole cap.
struct LoopTriangulator {
    let loops: [[SIMD2<Float>]]

    func triangulate() -> (points: [SIMD2<Float>], indices: [UInt32]) {
        let prepared = loops.compactMap { PreparedLoop(raw: $0) }
        guard !prepared.isEmpty else {
            return ([], [])
        }

        // Even-odd nesting depth for each loop, from an interior sample point.
        var depths = [Int](repeating: 0, count: prepared.count)
        for i in prepared.indices {
            var depth = 0
            for j in prepared.indices where j != i {
                if Geometry2D.contains(polygon: prepared[j].points, point: prepared[i].interiorPoint) {
                    depth += 1
                }
            }
            depths[i] = depth
        }

        var outputPoints = [SIMD2<Float>]()
        var outputIndices = [UInt32]()

        for outerIndex in prepared.indices where depths[outerIndex].isMultiple(of: 2) {
            // Immediate hole children sit exactly one nesting level deeper.
            let holes = prepared.indices.filter { holeIndex in
                depths[holeIndex] == depths[outerIndex] + 1
                    && Geometry2D.contains(
                        polygon: prepared[outerIndex].points,
                        point: prepared[holeIndex].interiorPoint
                    )
            }

            let outer = prepared[outerIndex].orientedCounterClockwise()
            let holeLoops = holes.map { prepared[$0].orientedClockwise() }
            appendTriangulation(outer: outer, holes: holeLoops, into: &outputPoints, indices: &outputIndices)
        }

        return (outputPoints, outputIndices)
    }

    // MARK: - Per-region triangulation

    private func appendTriangulation(
        outer: [SIMD2<Float>],
        holes: [[SIMD2<Float>]],
        into points: inout [SIMD2<Float>],
        indices: inout [UInt32]
    ) {
        var polygon = outer

        // Merge holes rightmost-first so a bridge is never blocked by a hole that
        // is farther right and still separate.
        let sortedHoles = holes.sorted { lhs, rhs in
            (lhs.max { $0.x < $1.x }?.x ?? 0) > (rhs.max { $0.x < $1.x }?.x ?? 0)
        }
        for hole in sortedHoles {
            polygon = Geometry2D.bridgeHole(into: polygon, hole: hole) ?? polygon
        }

        let localTriangles = Geometry2D.earClip(polygon)
        guard !localTriangles.isEmpty else {
            return
        }

        let baseIndex = UInt32(points.count)
        points.append(contentsOf: polygon)
        for triangle in localTriangles {
            indices.append(baseIndex + UInt32(triangle.0))
            indices.append(baseIndex + UInt32(triangle.1))
            indices.append(baseIndex + UInt32(triangle.2))
        }
    }
}

/// A cleaned, non-degenerate loop plus a cached interior sample point.
private struct PreparedLoop {
    var points: [SIMD2<Float>]
    var signedArea: Float
    var interiorPoint: SIMD2<Float>

    init?(raw: [SIMD2<Float>]) {
        let cleaned = Geometry2D.removeConsecutiveDuplicates(raw)
        guard cleaned.count >= 3 else {
            return nil
        }
        let area = Geometry2D.signedArea(cleaned)
        guard abs(area) > 1e-12 else {
            return nil
        }
        points = cleaned
        signedArea = area
        interiorPoint = Geometry2D.interiorPoint(of: cleaned) ?? cleaned.reduce(.zero, +) / Float(cleaned.count)
    }

    func orientedCounterClockwise() -> [SIMD2<Float>] {
        signedArea >= 0 ? points : Array(points.reversed())
    }

    func orientedClockwise() -> [SIMD2<Float>] {
        signedArea <= 0 ? points : Array(points.reversed())
    }
}

/// Stateless 2D polygon helpers shared by the triangulator.
enum Geometry2D {
    static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }

    static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else {
            return 0
        }
        var sum: Float = 0
        var previous = polygon[polygon.count - 1]
        for point in polygon {
            sum += cross(previous, point)
            previous = point
        }
        return sum * 0.5
    }

    static func removeConsecutiveDuplicates(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard polygon.count >= 2 else {
            return polygon
        }
        var result = [SIMD2<Float>]()
        result.reserveCapacity(polygon.count)
        for point in polygon {
            if let last = result.last, simd_distance(last, point) <= 1e-7 {
                continue
            }
            result.append(point)
        }
        if let first = result.first, let last = result.last,
           result.count >= 2, simd_distance(first, last) <= 1e-7 {
            result.removeLast()
        }
        return result
    }

    /// True when `point` lies inside `polygon`, via a crossing-number ray cast.
    static func contains(polygon: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let slope = (point.y - a.y) / (b.y - a.y)
                let crossingX = a.x + slope * (b.x - a.x)
                if point.x < crossingX {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    static func pointInTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ p: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(b - a, p - a)
        let d2 = cross(c - b, p - b)
        let d3 = cross(a - c, p - c)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    /// An interior point of a simple polygon: the centroid of its first ear.
    static func interiorPoint(of polygon: [SIMD2<Float>]) -> SIMD2<Float>? {
        let orientedCCW = signedArea(polygon) >= 0 ? polygon : polygon.reversed().map { $0 }
        let count = orientedCCW.count
        guard count >= 3 else {
            return nil
        }
        for k in 0..<count {
            let a = orientedCCW[(k + count - 1) % count]
            let b = orientedCCW[k]
            let c = orientedCCW[(k + 1) % count]
            if cross(b - a, c - a) <= 0 {
                continue
            }
            var isEar = true
            for j in 0..<count where j != (k + count - 1) % count && j != k && j != (k + 1) % count {
                if pointInTriangle(a, b, c, orientedCCW[j]) {
                    isEar = false
                    break
                }
            }
            if isEar {
                return (a + b + c) / 3
            }
        }
        return nil
    }

    /// Splices `hole` (clockwise) into `polygon` (counter-clockwise) with a zero-width
    /// bridge, yielding a single simple polygon, or `nil` if no bridge is visible.
    static func bridgeHole(into polygon: [SIMD2<Float>], hole: [SIMD2<Float>]) -> [SIMD2<Float>]? {
        guard hole.count >= 3, polygon.count >= 3 else {
            return nil
        }
        // Rightmost hole vertex is the bridge origin.
        var holeStart = 0
        for i in hole.indices where hole[i].x > hole[holeStart].x {
            holeStart = i
        }
        let m = hole[holeStart]

        guard let bridgeIndex = findBridgeIndex(polygon: polygon, from: m) else {
            return nil
        }

        var result = [SIMD2<Float>]()
        result.reserveCapacity(polygon.count + hole.count + 2)
        result.append(contentsOf: polygon[0...bridgeIndex])
        for offset in 0..<hole.count {
            result.append(hole[(holeStart + offset) % hole.count])
        }
        result.append(hole[holeStart])           // close the hole back to M
        result.append(contentsOf: polygon[bridgeIndex...]) // reconnect through P
        return result
    }

    /// Index of the polygon vertex to bridge a hole to, following the standard
    /// visibility test: shoot a ray +x from `m`, take the nearest crossed edge's
    /// rightward endpoint, then prefer any reflex vertex it occludes.
    private static func findBridgeIndex(polygon: [SIMD2<Float>], from m: SIMD2<Float>) -> Int? {
        let count = polygon.count
        var closestX = Float.greatestFiniteMagnitude
        var candidate: Int?
        for i in 0..<count {
            let a = polygon[i]
            let b = polygon[(i + 1) % count]
            guard (a.y > m.y) != (b.y > m.y) else {
                continue
            }
            let slope = (m.y - a.y) / (b.y - a.y)
            let crossingX = a.x + slope * (b.x - a.x)
            if crossingX >= m.x && crossingX < closestX {
                closestX = crossingX
                candidate = a.x > b.x ? i : (i + 1) % count
            }
        }

        guard var bestIndex = candidate else {
            return nil
        }

        // Refine: among reflex vertices inside triangle (m, intersection, P), pick
        // the one most aligned with the +x ray so the bridge stays inside.
        let intersection = SIMD2<Float>(closestX, m.y)
        let p = polygon[bestIndex]
        var bestAlignment = -Float.greatestFiniteMagnitude
        for i in 0..<count where i != bestIndex {
            let r = polygon[i]
            guard isReflex(polygon, at: i), pointInTriangle(m, intersection, p, r) else {
                continue
            }
            let direction = r - m
            let lengthSquared = simd_length_squared(direction)
            guard lengthSquared > 0 else {
                continue
            }
            let alignment = direction.x / sqrt(lengthSquared)
            if alignment > bestAlignment {
                bestAlignment = alignment
                bestIndex = i
            }
        }
        return bestIndex
    }

    private static func isReflex(_ polygon: [SIMD2<Float>], at index: Int) -> Bool {
        let count = polygon.count
        let previous = polygon[(index + count - 1) % count]
        let current = polygon[index]
        let next = polygon[(index + 1) % count]
        // Polygon is counter-clockwise here, so a reflex corner turns clockwise.
        return cross(current - previous, next - current) < 0
    }

    /// Ear-clips a simple, counter-clockwise polygon into triangle index triples.
    static func earClip(_ polygon: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        let count = polygon.count
        guard count >= 3 else {
            return []
        }
        if count == 3 {
            return [(0, 1, 2)]
        }

        var indices = Array(0..<count)
        var triangles = [(Int, Int, Int)]()
        triangles.reserveCapacity(count - 2)
        var guardCounter = 0
        let maxIterations = count * count + 16

        while indices.count > 3 && guardCounter < maxIterations {
            guardCounter += 1
            var clippedEar = false
            let ringCount = indices.count

            for k in 0..<ringCount {
                let previousIndex = indices[(k + ringCount - 1) % ringCount]
                let currentIndex = indices[k]
                let nextIndex = indices[(k + 1) % ringCount]
                let a = polygon[previousIndex]
                let b = polygon[currentIndex]
                let c = polygon[nextIndex]

                if cross(b - a, c - a) <= 0 {
                    continue // reflex or collinear corner: not an ear tip
                }

                var containsVertex = false
                for other in indices where other != previousIndex && other != currentIndex && other != nextIndex {
                    if pointInTriangle(a, b, c, polygon[other]) {
                        containsVertex = true
                        break
                    }
                }
                if containsVertex {
                    continue
                }

                triangles.append((previousIndex, currentIndex, nextIndex))
                indices.remove(at: k)
                clippedEar = true
                break
            }

            if !clippedEar {
                break // numerical dead end: finish with a fan below
            }
        }

        if indices.count == 3 {
            triangles.append((indices[0], indices[1], indices[2]))
        } else if indices.count > 3 {
            // Degenerate remainder: fan it so the cap is filled rather than holed.
            for k in 1..<(indices.count - 1) {
                triangles.append((indices[0], indices[k], indices[k + 1]))
            }
        }

        return triangles
    }
}
