import CoreGraphics
import Foundation
import simd

/// The rendering-engine operations the snap resolver needs — the seam that keeps
/// the measurement logic engine-agnostic. SceneKit's view conforms today; a
/// RealityKit host can conform without the resolver changing.
@MainActor
public protocol StepSnapScene {
    /// Projects a world-space point to view coordinates, or `nil` when it lies
    /// outside the view frustum (behind the camera, for example).
    func snapScreenPoint(for worldPoint: SIMD3<Float>) -> SIMD2<Float>?

    /// Surface crossings under a view point, nearest first. Only *snappable*
    /// surfaces appear — the model mesh and the section cap. The conformer is
    /// responsible for excluding everything else (measurement overlays, the
    /// cutting plane, grid, floor), since an overlay drawn on top of a target
    /// must not shadow it: that is the hit-test dead-zone bug.
    func snapSurfaceHits(at viewPoint: CGPoint) -> [StepSnapSurfaceHit]

    /// The camera's world-space position, for near-to-far candidate sorting.
    var snapCameraPosition: SIMD3<Float>? { get }
}

/// One surface crossing along the ray under the cursor.
public struct StepSnapSurfaceHit: Sendable {
    public enum Surface: Sendable {
        /// The imported model's tessellated mesh.
        case model
        /// The solid cap drawn over a cross-section cut.
        case sectionCap
    }

    public var surface: Surface
    public var worldPoint: SIMD3<Float>

    public init(surface: Surface, worldPoint: SIMD3<Float>) {
        self.surface = surface
        self.worldPoint = worldPoint
    }
}

/// Resolves a cursor position against a model's snap geometry, applying the
/// vertex → edge → face priority in screen space.
///
/// Engine-free: everything here is geometry over ``StepSnapModel`` plus the
/// three operations of ``StepSnapScene``.
public enum StepSnapResolver {
    private static let vertexThreshold: Float = 18 // points
    private static let edgeThreshold: Float = 13
    // Once a feature is snapped, keep it until the cursor leaves this expanded
    // radius, so the highlight doesn't flip between neighbours as the cursor
    // drifts (hysteresis).
    private static let stickiness: Float = 1.35

    @MainActor
    public static func resolve(
        view: some StepSnapScene,
        snapModel: StepSnapModel,
        viewPoint: CGPoint,
        sectionSnap: StepSectionSnap? = nil,
        sectionClip: SIMD4<Float>? = nil,
        previous: StepSnapResult? = nil
    ) -> StepSnapResult? {
        guard let anchor = surfaceAnchor(view: view, viewPoint: viewPoint, sectionClip: sectionClip) else {
            return nil
        }
        let worldHit = anchor.point
        let cursor = SIMD2<Float>(Float(viewPoint.x), Float(viewPoint.y))
        let radius = snapModel.queryRadius

        // Hysteresis is interleaved with the vertex → edge → face priority: a
        // sticky vertex holds against a fresh vertex, but a fresh vertex still
        // beats a sticky edge (so moving onto a corner always snaps to it).

        // 1. Vertices win when within threshold — the previous vertex sticks
        //    within an expanded radius so it doesn't flicker to a neighbour.
        if previous?.kind == .vertex, let sticky = stickyVertex(previous, cursor: cursor, in: view) {
            return sticky
        }
        var bestVertex: SIMD3<Float>?
        var bestVertexDistance = vertexThreshold * vertexThreshold
        func considerVertex(_ candidate: SIMD3<Float>) {
            guard let screen = view.snapScreenPoint(for: candidate) else { return }
            let distance = simd_distance_squared(screen, cursor)
            if distance < bestVertexDistance {
                bestVertexDistance = distance
                bestVertex = candidate
            }
        }
        // The cut outline's corners are always candidates. The mesh's own corners
        // are only considered off the cap, since whatever lies behind the cap is
        // hidden material the user can't see.
        for candidate in sectionSnap?.vertices ?? [] {
            considerVertex(candidate)
        }
        if !anchor.onCap {
            for candidate in snapModel.featureVertices(near: worldHit, radius: radius)
            where isVisible(candidate, sectionClip: sectionClip) {
                considerVertex(candidate)
            }
        }
        if let bestVertex {
            return StepSnapResult(point: bestVertex, kind: .vertex)
        }

        // 2. Otherwise the nearest feature edge — again sticking to the previous
        //    edge within an expanded radius before falling to a neighbour or face.
        if previous?.kind == .edge, let sticky = stickyEdge(previous, cursor: cursor, in: view) {
            return sticky
        }
        var bestEdge: StepLineSegment?
        var bestEdgePoint = worldHit
        var bestEdgeDistance = edgeThreshold * edgeThreshold
        func considerEdge(_ edge: StepLineSegment) {
            guard let a = view.snapScreenPoint(for: edge.start),
                  let b = view.snapScreenPoint(for: edge.end) else { return }
            let t = nearestParameterOnSegment(cursor, a, b)
            let closest = a + (b - a) * t
            let distance = simd_distance_squared(closest, cursor)
            if distance < bestEdgeDistance {
                bestEdgeDistance = distance
                bestEdge = edge
                bestEdgePoint = edge.start + (edge.end - edge.start) * t
            }
        }
        for edge in sectionSnap?.edges ?? [] {
            considerEdge(edge)
        }
        if !anchor.onCap {
            for edge in snapModel.featureEdges(near: worldHit, radius: radius) {
                // Only the part left after the cut: highlighting and snapping both
                // follow the segment, so this keeps them on visible geometry.
                guard let visible = visiblePortion(of: edge, sectionClip: sectionClip) else { continue }
                considerEdge(visible)
            }
        }
        if let bestEdge {
            let direction = bestEdge.end - bestEdge.start
            let line = simd_length(direction) > 0
                ? StepLine(point: bestEdgePoint, direction: simd_normalize(direction))
                : nil
            return StepSnapResult(point: bestEdgePoint, kind: .edge, edge: bestEdge, line: line)
        }

        // 3. Fall back to the surface point on its face — capturing the plane if
        // the face is planar, so two planar surfaces can be measured normal-to-normal.
        // Over the cap's interior the only things to measure to are its outline
        // edges and corners, so report no snap rather than a hidden face behind it.
        guard !anchor.onCap else {
            return nil
        }
        let region = snapModel.faceRegion(near: worldHit)
        var plane: StepPlane?
        if let region, let normal = snapModel.facePlaneNormal(region: region) {
            plane = StepPlane(normal: normal, point: worldHit)
        }
        return StepSnapResult(point: worldHit, kind: .face, regionID: region, plane: plane)
    }

    /// True when a point survives the section clip. Mesh features on the removed
    /// side are still in the snap model, so they have to be filtered out or the
    /// cursor snaps to geometry that isn't on screen.
    private static func isVisible(_ point: SIMD3<Float>, sectionClip: SIMD4<Float>?) -> Bool {
        guard let clip = sectionClip else { return true }
        return simd_dot(point, SIMD3<Float>(clip.x, clip.y, clip.z)) <= clip.w
    }

    /// The visible portion of a mesh edge, or `nil` when the section removed it.
    /// Cap-outline edges lie *on* the plane and are never clipped here.
    private static func visiblePortion(of edge: StepLineSegment, sectionClip: SIMD4<Float>?) -> StepLineSegment? {
        guard let clip = sectionClip else { return edge }
        return edge.clipped(by: clip)
    }

    /// The nearest *visible* surface under the cursor, and whether it is the
    /// section cap.
    private struct SurfaceAnchor {
        var point: SIMD3<Float>
        var onCap: Bool
    }

    @MainActor
    private static func surfaceAnchor(
        view: some StepSnapScene,
        viewPoint: CGPoint,
        sectionClip: SIMD4<Float>?
    ) -> SurfaceAnchor? {
        for hit in view.snapSurfaceHits(at: viewPoint) {
            switch hit.surface {
            case .sectionCap:
                return SurfaceAnchor(point: hit.worldPoint, onCap: true)
            case .model:
                // Sectioning discards fragments in the shader, so hit testing still
                // reports geometry on the removed side. Skip it: snapping must only
                // see what is actually visible.
                if let clip = sectionClip,
                   simd_dot(hit.worldPoint, SIMD3<Float>(clip.x, clip.y, clip.z)) > clip.w {
                    continue
                }
                return SurfaceAnchor(point: hit.worldPoint, onCap: false)
            }
        }
        return nil
    }

    // The right-click menu gathers a bit more generously than the snap does.
    private static let menuVertexThreshold: Float = 24
    private static let menuEdgeThreshold: Float = 20
    private static let menuCandidateLimit = 20

    /// Every snap target near the cursor — vertices, edges, and faces — gathered
    /// along the whole ray so obscured features behind the front surface are
    /// included too, sorted nearest-to-farthest from the camera. Used by the
    /// right-click disambiguation menu.
    @MainActor
    public static func candidates(
        view: some StepSnapScene,
        snapModel: StepSnapModel,
        viewPoint: CGPoint,
        boundsCenter: SIMD3<Float>,
        sectionSnap: StepSectionSnap? = nil,
        sectionClip: SIMD4<Float>? = nil
    ) -> [StepSnapCandidate] {
        guard let camPos = view.snapCameraPosition else { return [] }
        let cursor = SIMD2<Float>(Float(viewPoint.x), Float(viewPoint.y))
        let radius = snapModel.queryRadius

        let allHits = view.snapSurfaceHits(at: viewPoint)
        // Every mesh crossing along the ray, front to back — the anchors we gather
        // nearby vertices/edges/faces around.
        let surfaceHits = allHits.filter { $0.surface == .model }.map(\.worldPoint)
        let onCap = allHits.contains { $0.surface == .sectionCap }
        guard !surfaceHits.isEmpty || onCap else { return [] }

        var candidates = [StepSnapCandidate]()
        var seenVertices = Set<String>()
        var seenEdges = Set<String>()
        var seenRegions = Set<Int>()

        func key(_ p: SIMD3<Float>) -> String { String(format: "%.4f,%.4f,%.4f", p.x, p.y, p.z) }
        func label(_ kind: String, at world: SIMD3<Float>) -> String {
            let model = world + boundsCenter
            return String(format: "%@  (%.1f, %.1f, %.1f)", kind, model.x, model.y, model.z)
        }

        // The cross section's own corners and edges, wherever the cursor is.
        for vertex in sectionSnap?.vertices ?? [] {
            guard let screen = view.snapScreenPoint(for: vertex),
                  simd_distance(screen, cursor) <= menuVertexThreshold,
                  seenVertices.insert(key(vertex)).inserted else { continue }
            candidates.append(StepSnapCandidate(point: vertex, kind: .vertex, depth: simd_distance(camPos, vertex), label: label("Section vertex", at: vertex)))
        }
        for edge in sectionSnap?.edges ?? [] {
            guard let a = view.snapScreenPoint(for: edge.start),
                  let b = view.snapScreenPoint(for: edge.end) else { continue }
            let t = nearestParameterOnSegment(cursor, a, b)
            guard simd_distance(a + (b - a) * t, cursor) <= menuEdgeThreshold else { continue }
            guard seenEdges.insert(key(edge.start) + ">" + key(edge.end)).inserted else { continue }
            let point = edge.start + (edge.end - edge.start) * t
            let direction = edge.end - edge.start
            let line = simd_length(direction) > 0 ? StepLine(point: point, direction: simd_normalize(direction)) : nil
            candidates.append(StepSnapCandidate(point: point, kind: .edge, line: line, edge: edge, depth: simd_distance(camPos, point), label: label("Section edge", at: point)))
        }

        for worldHit in surfaceHits {
            // Vertices near the cursor at this depth.
            for vertex in snapModel.featureVertices(near: worldHit, radius: radius)
            where isVisible(vertex, sectionClip: sectionClip) {
                guard let screen = view.snapScreenPoint(for: vertex),
                      simd_distance(screen, cursor) <= menuVertexThreshold,
                      seenVertices.insert(key(vertex)).inserted else { continue }
                candidates.append(StepSnapCandidate(point: vertex, kind: .vertex, depth: simd_distance(camPos, vertex), label: label("Vertex", at: vertex)))
            }
            // Edges near the cursor at this depth.
            for rawEdge in snapModel.featureEdges(near: worldHit, radius: radius) {
                guard let edge = visiblePortion(of: rawEdge, sectionClip: sectionClip) else { continue }
                guard let a = view.snapScreenPoint(for: edge.start),
                      let b = view.snapScreenPoint(for: edge.end) else { continue }
                let t = nearestParameterOnSegment(cursor, a, b)
                guard simd_distance(a + (b - a) * t, cursor) <= menuEdgeThreshold else { continue }
                let edgeKey = key(edge.start) + ">" + key(edge.end)
                guard seenEdges.insert(edgeKey).inserted else { continue }
                let point = edge.start + (edge.end - edge.start) * t
                let direction = edge.end - edge.start
                let line = simd_length(direction) > 0 ? StepLine(point: point, direction: simd_normalize(direction)) : nil
                candidates.append(StepSnapCandidate(point: point, kind: .edge, line: line, edge: edge, depth: simd_distance(camPos, point), label: label("Edge", at: point)))
            }
            // The face this crossing lies on.
            if let region = snapModel.faceRegion(near: worldHit), seenRegions.insert(region).inserted {
                var plane: StepPlane?
                if let normal = snapModel.facePlaneNormal(region: region) {
                    plane = StepPlane(normal: normal, point: worldHit)
                }
                candidates.append(StepSnapCandidate(point: worldHit, kind: .face, plane: plane, depth: simd_distance(camPos, worldHit), label: label(plane != nil ? "Planar face" : "Face", at: worldHit)))
            }
        }

        return Array(candidates.sorted { $0.depth < $1.depth }.prefix(menuCandidateLimit))
    }

    /// The previous vertex, if the cursor is still within its expanded radius.
    @MainActor
    private static func stickyVertex(_ previous: StepSnapResult?, cursor: SIMD2<Float>, in view: some StepSnapScene) -> StepSnapResult? {
        guard let previous, previous.kind == .vertex,
              let screen = view.snapScreenPoint(for: previous.point),
              simd_distance(screen, cursor) <= vertexThreshold * stickiness else {
            return nil
        }
        return previous
    }

    /// The previous edge, if the cursor is still within its expanded radius. The
    /// edge keeps its identity but slides its point along its length to the cursor.
    @MainActor
    private static func stickyEdge(_ previous: StepSnapResult?, cursor: SIMD2<Float>, in view: some StepSnapScene) -> StepSnapResult? {
        guard let previous, previous.kind == .edge, let edge = previous.edge,
              let a = view.snapScreenPoint(for: edge.start),
              let b = view.snapScreenPoint(for: edge.end) else {
            return nil
        }
        let t = nearestParameterOnSegment(cursor, a, b)
        let closest = a + (b - a) * t
        guard simd_distance(closest, cursor) <= edgeThreshold * stickiness else {
            return nil
        }
        let point = edge.start + (edge.end - edge.start) * t
        let line = previous.line.map { StepLine(point: point, direction: $0.direction) }
        return StepSnapResult(point: point, kind: .edge, edge: edge, line: line)
    }

    private static func nearestParameterOnSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return 0 }
        return simd_clamp(simd_dot(p - a, ab) / lengthSquared, 0, 1)
    }
}
