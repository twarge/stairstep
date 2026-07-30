import Foundation
import simd

/// Which kind of geometry a measurement endpoint snapped to. Priority when more
/// than one is under the cursor is vertex, then edge, then face.
public enum StepSnapKind: String, Codable, Hashable, Sendable {
    case vertex
    case edge
    case face
}

/// A line segment in world space (used for edge highlights and the measurement line).
public struct StepLineSegment: Equatable, Sendable {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>

    public init(start: SIMD3<Float>, end: SIMD3<Float>) {
        self.start = start
        self.end = end
    }
}

public extension StepLineSegment {
    /// The portion of this segment still visible under a section clip, packed as
    /// `(nx, ny, nz, d)` in world space — a point is cut away when `dot(p, n) > d`,
    /// matching the shader. Returns `nil` when the whole segment is cut away.
    ///
    /// Without this the snap model's edges are the *un-sectioned* ones, so a cut
    /// edge highlights along its original full length and can be snapped to at a
    /// point that isn't on screen any more.
    func clipped(by clip: SIMD4<Float>) -> StepLineSegment? {
        let normal = SIMD3<Float>(clip.x, clip.y, clip.z)
        let startDistance = simd_dot(start, normal) - clip.w
        let endDistance = simd_dot(end, normal) - clip.w

        // Both ends kept, or both removed.
        if startDistance <= 0, endDistance <= 0 {
            return self
        }
        if startDistance > 0, endDistance > 0 {
            return nil
        }

        // Straddles the plane: cut it at the crossing and keep the surviving half.
        let span = startDistance - endDistance
        guard span != 0 else {
            return self
        }
        let crossing = start + (end - start) * (startDistance / span)
        return startDistance <= 0
            ? StepLineSegment(start: start, end: crossing)
            : StepLineSegment(start: crossing, end: end)
    }
}

/// A planar surface: a unit world-space normal and a point on the plane (the
/// point the user clicked). Captured when a planar face is selected so two of
/// them can be measured normal-to-normal.
public struct StepPlane: Equatable, Sendable {
    public var normal: SIMD3<Float>
    public var point: SIMD3<Float>

    public init(normal: SIMD3<Float>, point: SIMD3<Float>) {
        self.normal = normal
        self.point = point
    }
}

/// A line (edge): a unit world-space direction and a point on it. Captured when
/// an edge is selected so two of them can be measured normal-to-normal.
public struct StepLine: Equatable, Sendable {
    public var point: SIMD3<Float>
    public var direction: SIMD3<Float>

    public init(point: SIMD3<Float>, direction: SIMD3<Float>) {
        self.point = point
        self.direction = direction
    }
}

/// The result of resolving a cursor position against the snap model: the world
/// point to use plus what it snapped to (for highlighting).
public struct StepSnapResult: Equatable, Sendable {
    public var point: SIMD3<Float>
    public var kind: StepSnapKind
    /// The feature edge to highlight, when `kind == .edge`.
    public var edge: StepLineSegment?
    /// The face region to highlight, when `kind == .face`.
    public var regionID: Int?
    /// The plane, when the snapped face is planar.
    public var plane: StepPlane?
    /// The line, when the snap is an edge.
    public var line: StepLine?

    public init(
        point: SIMD3<Float>,
        kind: StepSnapKind,
        edge: StepLineSegment? = nil,
        regionID: Int? = nil,
        plane: StepPlane? = nil,
        line: StepLine? = nil
    ) {
        self.point = point
        self.kind = kind
        self.edge = edge
        self.regionID = regionID
        self.plane = plane
        self.line = line
    }
}

/// One possible snap target under the cursor, for the right-click disambiguation
/// menu. Carries everything needed to commit it as a measurement point plus a
/// human label and its distance from the camera (menus are sorted near-to-far).
public struct StepSnapCandidate: Equatable, Sendable {
    public var point: SIMD3<Float>
    public var kind: StepSnapKind
    public var plane: StepPlane?
    public var line: StepLine?
    public var edge: StepLineSegment?
    public var depth: Float
    public var label: String

    public init(
        point: SIMD3<Float>,
        kind: StepSnapKind,
        plane: StepPlane? = nil,
        line: StepLine? = nil,
        edge: StepLineSegment? = nil,
        depth: Float,
        label: String
    ) {
        self.point = point
        self.kind = kind
        self.plane = plane
        self.line = line
        self.edge = edge
        self.depth = depth
        self.label = label
    }

    public var measurePoint: StepMeasurePoint {
        StepMeasurePoint(position: point, kind: kind, plane: plane, line: line, edge: edge)
    }
}

/// One committed measurement endpoint.
public struct StepMeasurePoint: Equatable, Sendable {
    public var position: SIMD3<Float> // world space
    public var kind: StepSnapKind
    /// Set when the endpoint is a planar surface selection.
    public var plane: StepPlane?
    /// Set when the endpoint is an edge selection.
    public var line: StepLine?
    /// The picked edge itself, so a single selection can report its length. The
    /// `line` above is the infinite line through it, which has no length.
    public var edge: StepLineSegment?

    public init(
        position: SIMD3<Float>,
        kind: StepSnapKind,
        plane: StepPlane? = nil,
        line: StepLine? = nil,
        edge: StepLineSegment? = nil
    ) {
        self.position = position
        self.kind = kind
        self.plane = plane
        self.line = line
        self.edge = edge
    }

    /// True when this endpoint is just a position — a vertex, or a point on a
    /// non-planar face — carrying no line or plane to measure normal to.
    public var isPlainPoint: Bool {
        line == nil && plane == nil
    }
}

/// State of the distance-measurement tool. Endpoints are stored in world space
/// (the space the rendered scene uses), so they survive scene rebuilds and the
/// distance between them equals the model-space distance.
public struct StepMeasurement: Equatable, Sendable {
    public var isActive: Bool
    public var start: StepMeasurePoint?
    public var end: StepMeasurePoint?

    public init(
        isActive: Bool = false,
        start: StepMeasurePoint? = nil,
        end: StepMeasurePoint? = nil
    ) {
        self.isActive = isActive
        self.start = start
        self.end = end
    }

    public var isComplete: Bool {
        start != nil && end != nil
    }

    /// What the completed measurement represents, derived from the endpoint kinds:
    /// two planar surfaces or two edges measure normal-to-normal (with a
    /// not-parallel warning); anything else is a point-to-point distance.
    public var readout: StepMeasurementReadout? {
        guard let start else {
            return nil
        }
        guard let end else {
            // A single edge is worth reporting on its own: its length. Other single
            // selections — a vertex, a point on a face — have nothing to measure yet.
            guard let edge = start.edge else {
                return nil
            }
            return .edgeLength(distance: simd_distance(edge.start, edge.end), segment: edge)
        }
        // Two planar surfaces → distance along the common normal.
        if let a = start.plane, let b = end.plane {
            let absCosine = min(abs(simd_dot(a.normal, b.normal)), 1)
            if absCosine >= 0.99985 { // within ~1°
                let signed = simd_dot(a.normal, b.point - a.point)
                return .normalDistance(distance: abs(signed), from: a.point, to: a.point + a.normal * signed)
            }
            return .notParallel(angleDegrees: acos(absCosine) * 180 / .pi)
        }
        // Two edges → perpendicular distance between the parallel lines.
        if let a = start.line, let b = end.line {
            let absCosine = min(abs(simd_dot(a.direction, b.direction)), 1)
            if absCosine >= 0.99985 {
                let foot = b.point + simd_dot(a.point - b.point, a.direction) * a.direction
                return .normalDistance(distance: simd_distance(a.point, foot), from: a.point, to: foot)
            }
            return .notParallel(angleDegrees: acos(absCosine) * 180 / .pi)
        }
        // A vertex against an edge → perpendicular distance to that edge's line,
        // not to whichever point along it happened to be clicked. Oriented so the
        // drawn segment starts nearest the first endpoint picked.
        if let line = end.line, start.isPlainPoint {
            return Self.normalDistance(from: start.position, to: line)
        }
        if let line = start.line, end.isPlainPoint {
            let readout = Self.normalDistance(from: end.position, to: line)
            guard case .normalDistance(let distance, let point, let foot) = readout else {
                return readout
            }
            return .normalDistance(distance: distance, from: foot, to: point)
        }
        let delta = end.position - start.position
        return .pointToPoint(distance: simd_length(delta), delta: delta)
    }

    /// Perpendicular distance from `point` to the infinite line through `line`,
    /// reported as the segment from the point to its foot on the line.
    private static func normalDistance(from point: SIMD3<Float>, to line: StepLine) -> StepMeasurementReadout {
        let foot = line.point + simd_dot(point - line.point, line.direction) * line.direction
        return .normalDistance(distance: simd_distance(point, foot), from: point, to: foot)
    }

    /// Commits a picked point: fills `start`, then `end`, then begins a new
    /// measurement (the just-picked point becomes the new `start`).
    public mutating func addPoint(_ point: StepMeasurePoint) {
        if start == nil {
            start = point
            end = nil
        } else if end == nil {
            end = point
        } else {
            start = point
            end = nil
        }
    }

    public mutating func clearPoints() {
        start = nil
        end = nil
    }
}

/// What a completed measurement conveys.
public enum StepMeasurementReadout: Equatable, Sendable {
    /// The length of a single selected edge, before a second selection turns it
    /// into a distance.
    case edgeLength(distance: Float, segment: StepLineSegment)
    /// Straight-line distance between two points, plus per-axis components.
    case pointToPoint(distance: Float, delta: SIMD3<Float>)
    /// Perpendicular gap between two parallel surfaces or edges, with the segment
    /// to draw between them.
    case normalDistance(distance: Float, from: SIMD3<Float>, to: SIMD3<Float>)
    /// Two surfaces/edges were selected but they are not parallel.
    case notParallel(angleDegrees: Float)
}
