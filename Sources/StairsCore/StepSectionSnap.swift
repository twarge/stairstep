import Foundation
import simd

/// Snappable geometry of a cross-section's cut outline: its real corners and
/// full-length edges, in world space (the space the rendered scene uses).
///
/// Slicing a tessellated mesh puts an extra boundary point wherever the plane
/// crosses an interior tessellation edge, so a single straight run of the outline
/// arrives as several collinear points. Those are removed here, leaving one edge
/// per straight run between two genuine corners — which is what a measurement
/// should snap to.
public struct StepSectionSnap: Sendable {
    public var vertices: [SIMD3<Float>]
    public var edges: [StepLineSegment]

    public var isEmpty: Bool {
        vertices.isEmpty && edges.isEmpty
    }

    public init(vertices: [SIMD3<Float>] = [], edges: [StepLineSegment] = []) {
        self.vertices = vertices
        self.edges = edges
    }

    /// Builds the snap set from a cap's outline loops.
    ///
    /// - Parameters:
    ///   - loops: Closed loops in model space, as returned by ``StepSectionCapMesh/loops``.
    ///   - center: The model bounds center; positions render at `model - center`.
    ///   - largestDimension: Model size, used to scale the collinearity tolerance.
    public init(loops: [[SIMD3<Float>]], center: SIMD3<Float>, largestDimension: Float) {
        let tolerance = max(largestDimension * 1e-4, 1e-7)
        var vertices = [SIMD3<Float>]()
        var edges = [StepLineSegment]()

        for loop in loops {
            let corners = Self.corners(of: loop.map { $0 - center }, tolerance: tolerance)
            guard corners.count >= 2 else { continue }
            vertices.append(contentsOf: corners)
            for index in corners.indices {
                let next = corners[(index + 1) % corners.count]
                let segment = StepLineSegment(start: corners[index], end: next)
                if simd_distance(segment.start, segment.end) > tolerance {
                    edges.append(segment)
                }
            }
        }

        self.init(vertices: vertices, edges: edges)
    }

    /// Drops points that sit on the straight line between their two neighbours,
    /// leaving only the loop's genuine corners. Tested against each point's
    /// original neighbours in one pass, which collapses a whole collinear run.
    private static func corners(of loop: [SIMD3<Float>], tolerance: Float) -> [SIMD3<Float>] {
        let count = loop.count
        guard count >= 3 else {
            return loop
        }
        var result = [SIMD3<Float>]()
        result.reserveCapacity(count)
        for index in 0..<count {
            let previous = loop[(index + count - 1) % count]
            let current = loop[index]
            let next = loop[(index + 1) % count]
            let span = next - previous
            let spanLength = simd_length(span)
            guard spanLength > tolerance else {
                result.append(current) // neighbours coincide; keep the point
                continue
            }
            // Perpendicular distance from `current` to the line previous→next.
            let offset = current - previous
            let distance = simd_length(simd_cross(offset, span / spanLength))
            if distance > tolerance {
                result.append(current)
            }
        }
        // An entirely straight (degenerate) loop collapses to nothing; keep the
        // raw points rather than losing the outline.
        return result.count >= 3 ? result : loop
    }
}
