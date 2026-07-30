#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO

struct IconSpec {
    var pointSize: Int
    var scale: Int

    var pixelSize: Int {
        pointSize * scale
    }

    var fileName: String {
        if scale == 1 {
            "icon_\(pointSize)x\(pointSize).png"
        } else {
            "icon_\(pointSize)x\(pointSize)@\(scale)x.png"
        }
    }
}

struct IOSIconSpec {
    var idiom: String
    var size: String
    var scale: Int
    var pixelSize: Int

    var fileName: String {
        let normalizedSize = size.replacingOccurrences(of: ".", with: "_")
        return "icon-\(idiom)-\(normalizedSize)@\(scale)x.png"
    }
}

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let resourcesURL = rootURL.appendingPathComponent("App/Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")
let assetCatalogURL = resourcesURL.appendingPathComponent("Assets.xcassets", isDirectory: true)
let iosAppIconURL = assetCatalogURL.appendingPathComponent("AppIcon.appiconset", isDirectory: true)

let specs = [
    IconSpec(pointSize: 16, scale: 1),
    IconSpec(pointSize: 16, scale: 2),
    IconSpec(pointSize: 32, scale: 1),
    IconSpec(pointSize: 32, scale: 2),
    IconSpec(pointSize: 128, scale: 1),
    IconSpec(pointSize: 128, scale: 2),
    IconSpec(pointSize: 256, scale: 1),
    IconSpec(pointSize: 256, scale: 2),
    IconSpec(pointSize: 512, scale: 1),
    IconSpec(pointSize: 512, scale: 2)
]

let iosSpecs = [
    IOSIconSpec(idiom: "iphone", size: "20x20", scale: 2, pixelSize: 40),
    IOSIconSpec(idiom: "iphone", size: "20x20", scale: 3, pixelSize: 60),
    IOSIconSpec(idiom: "iphone", size: "29x29", scale: 2, pixelSize: 58),
    IOSIconSpec(idiom: "iphone", size: "29x29", scale: 3, pixelSize: 87),
    IOSIconSpec(idiom: "iphone", size: "40x40", scale: 2, pixelSize: 80),
    IOSIconSpec(idiom: "iphone", size: "40x40", scale: 3, pixelSize: 120),
    IOSIconSpec(idiom: "iphone", size: "60x60", scale: 2, pixelSize: 120),
    IOSIconSpec(idiom: "iphone", size: "60x60", scale: 3, pixelSize: 180),
    IOSIconSpec(idiom: "ipad", size: "20x20", scale: 1, pixelSize: 20),
    IOSIconSpec(idiom: "ipad", size: "20x20", scale: 2, pixelSize: 40),
    IOSIconSpec(idiom: "ipad", size: "29x29", scale: 1, pixelSize: 29),
    IOSIconSpec(idiom: "ipad", size: "29x29", scale: 2, pixelSize: 58),
    IOSIconSpec(idiom: "ipad", size: "40x40", scale: 1, pixelSize: 40),
    IOSIconSpec(idiom: "ipad", size: "40x40", scale: 2, pixelSize: 80),
    IOSIconSpec(idiom: "ipad", size: "76x76", scale: 2, pixelSize: 152),
    IOSIconSpec(idiom: "ipad", size: "83.5x83.5", scale: 2, pixelSize: 167),
    IOSIconSpec(idiom: "ios-marketing", size: "1024x1024", scale: 1, pixelSize: 1024)
]

try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: assetCatalogURL, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iosAppIconURL)
try fileManager.createDirectory(at: iosAppIconURL, withIntermediateDirectories: true)

for spec in specs {
    try drawIcon(pixelSize: spec.pixelSize, to: iconsetURL.appendingPathComponent(spec.fileName))
}

for spec in iosSpecs {
    try drawIcon(
        pixelSize: spec.pixelSize,
        to: iosAppIconURL.appendingPathComponent(spec.fileName),
        opaqueBackground: true
    )
}

try writeAssetCatalogContents(to: assetCatalogURL.appendingPathComponent("Contents.json"))
try writeIOSAppIconContents(specs: iosSpecs, to: iosAppIconURL.appendingPathComponent("Contents.json"))

try runIconutil(iconsetURL: iconsetURL, icnsURL: icnsURL)
print(icnsURL.path)
print(iosAppIconURL.path)

func drawIcon(pixelSize: Int, to url: URL, opaqueBackground: Bool = false) throws {
    let size = CGFloat(pixelSize)
    let bitmapInfo = opaqueBackground
        ? CGImageAlphaInfo.noneSkipLast.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let bitmapContext = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else {
        throw CocoaError(.coderInvalidValue)
    }

    let graphicsContext = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
    let previousContext = NSGraphicsContext.current
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.current = previousContext }

    graphicsContext.imageInterpolation = .high
    let context = bitmapContext
    context.setShouldAntialias(true)
    if opaqueBackground {
        NSColor(calibratedRed: 0.00, green: 0.08, blue: 0.05, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    } else {
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    }

    drawBackground(size: size)
    drawStairs(size: size)

    guard let image = bitmapContext.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

func writeAssetCatalogContents(to url: URL) throws {
    let contents = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    try contents.write(to: url, atomically: true, encoding: .utf8)
}

func writeIOSAppIconContents(specs: [IOSIconSpec], to url: URL) throws {
    let imageEntries = specs.map { spec in
        """
        {
          "filename" : "\(spec.fileName)",
          "idiom" : "\(spec.idiom)",
          "scale" : "\(spec.scale)x",
          "size" : "\(spec.size)"
        }
        """
    }.joined(separator: ",\n")

    let contents = """
    {
      "images" : [
    \(imageEntries.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    try contents.write(to: url, atomically: true, encoding: .utf8)
}

func drawBackground(size: CGFloat) {
    let rect = NSRect(
        x: size * 0.055,
        y: size * 0.055,
        width: size * 0.89,
        height: size * 0.89
    )
    let radius = size * 0.205
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.025)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.01, green: 0.09, blue: 0.05, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.00, green: 0.08, blue: 0.05, alpha: 1)
    ])
    gradient?.draw(in: path, angle: -38)

    drawRimReticle(size: size)

    NSColor(calibratedRed: 0.92, green: 0.98, blue: 0.72, alpha: 0.22).setStroke()
    path.lineWidth = max(size * 0.006, 1)
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
}

func drawRimReticle(size: CGFloat) {
    let reticleColor = NSColor(calibratedRed: 0.93, green: 0.99, blue: 0.68, alpha: 0.56)
    let inset = size * 0.105
    let tickLength = size * 0.075
    let lineWidth = max(size * 0.006, 1)
    let rect = NSRect(
        x: inset,
        y: inset,
        width: size - inset * 2,
        height: size - inset * 2
    )
    let rim = NSBezierPath(roundedRect: rect, xRadius: size * 0.155, yRadius: size * 0.155)
    rim.lineWidth = lineWidth
    reticleColor.withAlphaComponent(0.24).setStroke()
    rim.stroke()

    let ticks = [
        (NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY - tickLength)),
        (NSPoint(x: rect.midX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY + tickLength)),
        (NSPoint(x: rect.minX, y: rect.midY), NSPoint(x: rect.minX + tickLength, y: rect.midY)),
        (NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.maxX - tickLength, y: rect.midY))
    ]

    for tick in ticks {
        let path = NSBezierPath()
        path.move(to: tick.0)
        path.line(to: tick.1)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        reticleColor.setStroke()
        path.stroke()
    }

    let crosshairSize = size * 0.052
    let center = NSPoint(x: rect.midX, y: rect.midY)
    for segment in [
        (NSPoint(x: center.x - crosshairSize, y: center.y), NSPoint(x: center.x - crosshairSize * 0.28, y: center.y)),
        (NSPoint(x: center.x + crosshairSize * 0.28, y: center.y), NSPoint(x: center.x + crosshairSize, y: center.y)),
        (NSPoint(x: center.x, y: center.y - crosshairSize), NSPoint(x: center.x, y: center.y - crosshairSize * 0.28)),
        (NSPoint(x: center.x, y: center.y + crosshairSize * 0.28), NSPoint(x: center.x, y: center.y + crosshairSize))
    ] {
        let path = NSBezierPath()
        path.move(to: segment.0)
        path.line(to: segment.1)
        path.lineWidth = max(lineWidth * 0.75, 1)
        path.lineCapStyle = .round
        reticleColor.withAlphaComponent(0.32).setStroke()
        path.stroke()
    }
}

func drawStairs(size: CGFloat) {
    drawPlane(size: size)

    let topColor = NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.58, alpha: 1)
    let frontColor = NSColor(calibratedRed: 0.92, green: 0.74, blue: 0.32, alpha: 1)
    let sideColor = NSColor(calibratedRed: 0.64, green: 0.49, blue: 0.19, alpha: 1)
    let edgeColor = NSColor(calibratedRed: 1.00, green: 0.99, blue: 0.78, alpha: 0.78)
    let lowerEdgeColor = NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.07, alpha: 0.38)

    for step in stride(from: 2, through: 0, by: -1) {
        let height = Double(step + 1) * 0.82
        let z = Double(2 - step) * 0.88
        drawBlock(
            x: -0.10,
            z: z,
            width: 3.30,
            depth: 0.92,
            height: height,
            size: size,
            topColor: topColor,
            frontColor: frontColor,
            sideColor: sideColor,
            edgeColor: edgeColor,
            lowerEdgeColor: lowerEdgeColor
        )
    }
}

func drawPlane(size: CGFloat) {
    let planeFill = NSColor(calibratedRed: 0.09, green: 0.31, blue: 0.18, alpha: 0.92)
    let planeStroke = NSColor(calibratedRed: 0.78, green: 0.89, blue: 0.45, alpha: 0.58)
    let planeShadow = NSColor.black.withAlphaComponent(0.24)
    let points = [
        project(-0.54, 0, -0.32, size: size),
        project(3.66, 0, -0.32, size: size),
        project(3.66, 0, 3.10, size: size),
        project(-0.54, 0, 3.10, size: size)
    ]

    let dropped = points.map { NSPoint(x: $0.x, y: $0.y - size * 0.018) }
    drawFace(dropped, fill: planeShadow, stroke: .clear, lineWidth: 0)
    drawFace(points, fill: planeFill, stroke: planeStroke, lineWidth: size * 0.006)

    for x in stride(from: -0.1, through: 3.3, by: 1.1) {
        let path = NSBezierPath()
        path.move(to: project(x, 0.002, -0.24, size: size))
        path.line(to: project(x, 0.002, 3.00, size: size))
        planeStroke.withAlphaComponent(0.18).setStroke()
        path.lineWidth = max(size * 0.0025, 0.75)
        path.stroke()
    }
}

func drawBlock(
    x: Double,
    z: Double,
    width: Double,
    depth: Double,
    height: Double,
    size: CGFloat,
    topColor: NSColor,
    frontColor: NSColor,
    sideColor: NSColor,
    edgeColor: NSColor,
    lowerEdgeColor: NSColor
) {
    let b = project(x + width, 0, z, size: size)
    let c = project(x + width, 0, z + depth, size: size)
    let d = project(x, 0, z + depth, size: size)
    let aa = project(x, height, z, size: size)
    let bb = project(x + width, height, z, size: size)
    let cc = project(x + width, height, z + depth, size: size)
    let dd = project(x, height, z + depth, size: size)

    drawFace([b, bb, cc, c], fill: sideColor, stroke: lowerEdgeColor, lineWidth: size * 0.006)
    drawFace([c, cc, dd, d], fill: frontColor, stroke: lowerEdgeColor, lineWidth: size * 0.006)
    drawFace([aa, bb, cc, dd], fill: topColor, stroke: edgeColor, lineWidth: size * 0.007)

    let highlight = NSBezierPath()
    highlight.move(to: aa)
    highlight.line(to: bb)
    highlight.line(to: cc)
    edgeColor.withAlphaComponent(0.72).setStroke()
    highlight.lineWidth = max(size * 0.0045, 1)
    highlight.lineCapStyle = .round
    highlight.lineJoinStyle = .round
    highlight.stroke()
}

func project(_ x: Double, _ y: Double, _ z: Double, size: CGFloat) -> NSPoint {
    let unit = Double(size * 0.095)
    let vertical = Double(size * 0.082)
    let originX = Double(size * 0.465)
    let originY = Double(size * 0.575)

    return NSPoint(
        x: originX + (x - z) * unit,
        y: originY - (x + z) * unit * 0.43 + y * vertical
    )
}

func drawFace(_ points: [NSPoint], fill: NSColor, stroke: NSColor, lineWidth: CGFloat) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.close()

    fill.setFill()
    path.fill()
    stroke.setStroke()
    path.lineWidth = max(lineWidth, 0.75)
    path.lineJoinStyle = .round
    path.stroke()
}

func runIconutil(iconsetURL: URL, icnsURL: URL) throws {
    try? fileManager.removeItem(at: icnsURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = [
        "-c", "icns",
        "-o", icnsURL.path,
        iconsetURL.path
    ]

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}
