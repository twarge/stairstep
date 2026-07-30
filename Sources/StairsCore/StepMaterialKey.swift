import Foundation

public struct StepMaterialKey: Hashable, Comparable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = max(0, min(255, red))
        self.green = max(0, min(255, green))
        self.blue = max(0, min(255, blue))
    }

    public init(color: SIMD3<Float>) {
        self.init(
            red: Int((min(max(color.x, 0), 1) * 255).rounded()),
            green: Int((min(max(color.y, 0), 1) * 255).rounded()),
            blue: Int((min(max(color.z, 0), 1) * 255).rounded())
        )
    }

    public static func < (lhs: StepMaterialKey, rhs: StepMaterialKey) -> Bool {
        if lhs.red != rhs.red {
            return lhs.red < rhs.red
        }
        if lhs.green != rhs.green {
            return lhs.green < rhs.green
        }
        return lhs.blue < rhs.blue
    }

    public var platformColor: PlatformColor {
        PlatformColor.stairsRGB(red: red, green: green, blue: blue)
    }
}
