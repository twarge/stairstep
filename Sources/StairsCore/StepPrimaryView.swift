import Foundation
import simd

/// The named camera viewpoints: six axis-aligned views on keys 1–6 (axis
/// order: +X, −X, +Y, −Y, +Z, −Z) and three axonometric views on i, d, t.
/// The camera moves onto the view's direction at its current distance,
/// looking at the model's center.
public enum StepPrimaryView: CaseIterable, Sendable {
    case right      // 1: +X
    case left       // 2: −X
    case top        // 3: +Y
    case bottom     // 4: −Y
    case front      // 5: +Z
    case back       // 6: −Z
    case isometric  // i
    case dimetric   // d
    case trimetric  // t

    public init?(key: String) {
        switch key.lowercased() {
        case "1": self = .right
        case "2": self = .left
        case "3": self = .top
        case "4": self = .bottom
        case "5": self = .front
        case "6": self = .back
        case "i": self = .isometric
        case "d": self = .dimetric
        case "t": self = .trimetric
        default: return nil
        }
    }

    /// Every key that selects a view — the canvas key handlers register these.
    public static let allKeys = ["1", "2", "3", "4", "5", "6", "i", "d", "t"]

    /// Menu presentation, reading order: the six faces, then the axonometrics.
    public static let axisCases: [StepPrimaryView] = [.front, .back, .left, .right, .top, .bottom]
    public static let axonometricCases: [StepPrimaryView] = [.isometric, .dimetric, .trimetric]

    /// Unit direction from the model's center toward the camera.
    ///
    /// The axonometric directions are the classical drafting constructions:
    /// isometric foreshortens all three axes equally; dimetric is the standard
    /// engineering 1 : 1 : ½ view (the receding axis drawn at half scale, axes
    /// on paper at ~7° and ~42°); trimetric turns 30° and tips 20°, leaving
    /// all three axes distinctly foreshortened.
    public var direction: SIMD3<Float> {
        switch self {
        case .right: return SIMD3(1, 0, 0)
        case .left: return SIMD3(-1, 0, 0)
        case .top: return SIMD3(0, 1, 0)
        case .bottom: return SIMD3(0, -1, 0)
        case .front: return SIMD3(0, 0, 1)
        case .back: return SIMD3(0, 0, -1)
        case .isometric:
            return simd_normalize(SIMD3(1, 1, 1))
        case .dimetric:
            // Solving f_x = f_y, f_z = f_x / 2 with f_i = sqrt(1 - v_i²)
            // gives v = (1, 1, √7) / 3.
            return SIMD3(1, 1, Float(7).squareRoot()) / 3
        case .trimetric:
            let azimuth = Float(30) * .pi / 180
            let elevation = Float(20) * .pi / 180
            return SIMD3(
                sin(azimuth) * cos(elevation),
                sin(elevation),
                cos(azimuth) * cos(elevation)
            )
        }
    }

    /// Up hint for the look-at. The side views keep +Y up; the top and bottom
    /// views (where +Y is degenerate) orient the screen with +X to the right —
    /// top shows +Z toward the viewer's bottom edge, the CAD convention.
    public var upHint: SIMD3<Float> {
        switch self {
        case .top: return SIMD3(0, 0, -1)
        case .bottom: return SIMD3(0, 0, 1)
        default: return SIMD3(0, 1, 0)
        }
    }

    public var displayName: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .front: return "Front"
        case .back: return "Back"
        case .isometric: return "Isometric"
        case .dimetric: return "Dimetric"
        case .trimetric: return "Trimetric"
        }
    }
}

/// A one-shot request to jump the camera to a named viewpoint, delivered from
/// the View menu down to whichever canvas is live. The fresh `id` is what the
/// canvases react to, so selecting the same view twice still fires.
public struct StepPrimaryViewRequest: Equatable, Sendable {
    public var id: UUID
    public var view: StepPrimaryView

    public init(view: StepPrimaryView) {
        self.id = UUID()
        self.view = view
    }
}
