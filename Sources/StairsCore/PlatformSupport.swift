import CoreGraphics
import Foundation
import SceneKit

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#endif

public extension PlatformColor {
    static func stairsBackground(isDarkMode: Bool) -> PlatformColor {
        if isDarkMode {
            PlatformColor(red: 0, green: 0, blue: 0, alpha: 1)
        } else {
            PlatformColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    static var stairsGrid: PlatformColor {
        PlatformColor(red: 0.43, green: 0.47, blue: 0.52, alpha: 0.28)
    }

    static var stairsNeutralModel: PlatformColor {
        PlatformColor(red: 0.70, green: 0.73, blue: 0.76, alpha: 1)
    }

    /// The system selection / highlight color — the user's accent color on macOS,
    /// the tint color on iOS — resolved to concrete components so SceneKit
    /// materials and CoreGraphics images render the same shade.
    static var stairsSelection: PlatformColor {
        #if os(macOS)
        return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        #else
        return UIColor.tintColor
        #endif
    }

    static func stairsRGB(red: Int, green: Int, blue: Int, alpha: CGFloat = 1) -> PlatformColor {
        PlatformColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
    }

    /// The color's sRGB red/green/blue as a `float3`, for shader uniforms.
    var stairsRGBComponents: SIMD3<Float> {
        #if os(macOS)
        let resolved = usingColorSpace(.sRGB) ?? self
        return SIMD3<Float>(Float(resolved.redComponent), Float(resolved.greenComponent), Float(resolved.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
        #endif
    }

    /// The color's red/green/blue converted to **linear** space, for shader
    /// uniforms. SceneKit shades linearly and converts material colours for you,
    /// but a raw uniform is used as-is — passing sRGB components straight through
    /// renders visibly too light.
    var stairsLinearRGBComponents: SIMD3<Float> {
        func linear(_ channel: Float) -> Float {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let srgb = stairsRGBComponents
        return SIMD3<Float>(linear(srgb.x), linear(srgb.y), linear(srgb.z))
    }

    /// Parses `#RRGGBB` (case-insensitive, optional leading `#`) as an sRGB color.
    static func stairsColor(hexString: String) -> PlatformColor? {
        var string = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        #if os(macOS)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    /// `#RRGGBB` for the color's sRGB components.
    var stairsHexString: String {
        let rgb = stairsRGBComponents
        func channel(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }
}

extension SCNVector3 {
    init(_ vector: SIMD3<Float>) {
        self.init(CGFloat(vector.x), CGFloat(vector.y), CGFloat(vector.z))
    }
}
