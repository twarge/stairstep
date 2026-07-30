import Foundation
import simd

/// The axis a cross-section plane is perpendicular to, expressed in the scene's
/// coordinate space (the same space the imported mesh and ``StepBounds`` live
/// in). A plane on ``x`` slices along the world X axis, and so on.
public enum StepSectionAxis: String, Codable, Hashable, Sendable, CaseIterable {
    case x
    case y
    case z

    public var index: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }

    public var displayName: String {
        switch self {
        case .x: "X"
        case .y: "Y"
        case .z: "Z"
        }
    }
}

/// A user-defined cross-section (clipping) plane.
///
/// The plane is axis-aligned and positioned by ``offset``, a coordinate in the
/// model's own space along ``axis`` — i.e. the value ranges over
/// `bounds.min...bounds.max` for that axis and reads the same as the vertex
/// coordinates shown in the inspector. Everything past the plane on the removed
/// side is clipped away so the viewer can see into the cut; ``isFlipped`` swaps
/// which side is kept.
public struct StepSectionPlane: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var axis: StepSectionAxis
    /// Position of the plane along ``axis`` in model space.
    public var offset: Float
    /// Keeps the opposite half when `true`. The default keeps the lower-coordinate
    /// half so the cut faces the default camera (which sits in the +X/+Y/+Z octant).
    public var isFlipped: Bool
    /// Fills the exposed cut with a solid cap polygon when `true`; otherwise the
    /// cut is left open, revealing the model's hollow interior walls.
    public var showsCap: Bool

    public init(
        isEnabled: Bool = false,
        axis: StepSectionAxis = .x,
        offset: Float = 0,
        isFlipped: Bool = false,
        showsCap: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.axis = axis
        self.offset = offset
        self.isFlipped = isFlipped
        self.showsCap = showsCap
    }

    /// Outward normal of the cut face, in model space. Points toward the removed
    /// half so the cap (and interior walls) face the viewer on the default side.
    public var cutNormal: SIMD3<Float> {
        var normal = SIMD3<Float>(repeating: 0)
        normal[axis.index] = isFlipped ? -1 : 1
        return normal
    }

    /// Clip plane in **world** space, packed for the shader as `(nx, ny, nz, d)`.
    ///
    /// The mesh is drawn under a node translated by `-center`, so a model-space
    /// coordinate `p` renders at world position `w = p - center`. A fragment is
    /// discarded when `dot(w, n) > d`.
    ///
    /// - Parameter center: The model bounds center (see ``StepBounds/center``).
    public func clipVector(center: SIMD3<Float>) -> SIMD4<Float> {
        let axisIndex = axis.index
        var normal = SIMD3<Float>(repeating: 0)
        normal[axisIndex] = 1
        var distance = offset - center[axisIndex]
        if isFlipped {
            normal = -normal
            distance = -distance
        }
        return SIMD4<Float>(normal.x, normal.y, normal.z, distance)
    }

    /// Clamps ``offset`` into `bounds` for the current axis, nudged inward so an
    /// enabled plane always intersects the model instead of sitting flush with a face.
    public mutating func clampOffset(to bounds: StepBounds) {
        let lower = bounds.minValue(axis: axis)
        let upper = bounds.maxValue(axis: axis)
        guard lower.isFinite, upper.isFinite, upper > lower else {
            return
        }
        let inset = (upper - lower) * 0.001
        offset = min(max(offset, lower + inset), upper - inset)
    }
}

/// Trims geometry to the part a section plane leaves visible.
public enum StepSectionClip {
    /// Clips a flat list of triangle vertex triples against a section clip packed
    /// as `(nx, ny, nz, d)` — a point is cut away when `dot(p, n) > d`, matching the
    /// shader — and returns the surviving parts, re-triangulated.
    ///
    /// A triangle crossing the plane becomes a quadrilateral, so the result is
    /// fan-triangulated rather than clipped in place.
    public static func clipTriangles(_ vertices: [SIMD3<Float>], by clip: SIMD4<Float>) -> [SIMD3<Float>] {
        let normal = SIMD3<Float>(clip.x, clip.y, clip.z)
        var result = [SIMD3<Float>]()
        result.reserveCapacity(vertices.count)

        var index = 0
        while index + 2 < vertices.count {
            defer { index += 3 }
            let triangle = [vertices[index], vertices[index + 1], vertices[index + 2]]
            let distances = triangle.map { simd_dot($0, normal) - clip.w }

            if distances.allSatisfy({ $0 <= 0 }) {
                result.append(contentsOf: triangle) // wholly visible
                continue
            }
            if distances.allSatisfy({ $0 > 0 }) {
                continue // wholly cut away
            }

            // Sutherland–Hodgman against the single half-space.
            var polygon = [SIMD3<Float>]()
            for corner in 0..<3 {
                let next = (corner + 1) % 3
                let current = triangle[corner], following = triangle[next]
                let currentDistance = distances[corner], nextDistance = distances[next]

                if currentDistance <= 0 {
                    polygon.append(current)
                }
                if (currentDistance <= 0) != (nextDistance <= 0) {
                    let span = currentDistance - nextDistance
                    if span != 0 {
                        polygon.append(current + (following - current) * (currentDistance / span))
                    }
                }
            }

            guard polygon.count >= 3 else { continue }
            for corner in 1..<(polygon.count - 1) {
                result.append(polygon[0])
                result.append(polygon[corner])
                result.append(polygon[corner + 1])
            }
        }
        return result
    }
}

public extension StepBounds {
    func minValue(axis: StepSectionAxis) -> Float {
        switch axis {
        case .x: minX
        case .y: minY
        case .z: minZ
        }
    }

    func maxValue(axis: StepSectionAxis) -> Float {
        switch axis {
        case .x: maxX
        case .y: maxY
        case .z: maxZ
        }
    }
}
