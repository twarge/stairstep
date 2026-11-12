#!/usr/bin/env swift

// Writes the app icon: an Icon Composer bundle for macOS and iOS, and an image
// stack for visionOS.
//
//     swift scripts/generate_app_icon.swift        (or `make icon`)
//
// The picture is three steps standing on a work plane, on a green ground, cut
// through the way the app's cross-section tool cuts a model: the stepped end is
// the cut face, in the app's default fill with its diagonal hatching.
//
// App/Resources/AppIcon.icon is icon.json plus one SVG per layer. Xcode's asset
// compiler turns it into every size each platform needs and applies the system
// shape and the glass, dark, clear and tinted treatments, so the artwork here
// is full bleed and carries no mask, rim or shadow of its own. From back to
// front the layers are the ground (the fill in icon.json), Plane, Body (the
// risers), Section (the cut face) and Treads.
//
// visionOS takes nothing from that bundle. Its icon is
// App/Resources/Assets.xcassets/AppIcon.solidimagestack: the same shapes drawn
// into three 1024 px PNGs (ground, work plane, staircase) that the system
// spreads in depth and crops to a circle. The asset compiler gives each
// platform the one it understands, under the one name AppIcon.
//
// Both are committed, so this only needs running when the design changes. To
// look at the Icon Composer result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         App/Resources/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Foundation, CoreGraphics and ImageIO only: no AppKit, so it starts in a
// second or two.

import CoreGraphics
import Foundation
import ImageIO

// MARK: Colours

let treadColor = "#FFF1A4"
let treadEdgeColor = "#FFFCC7"
let riserColor = "#EFC764"
let sideColor = "#B38F3F"
/// The cut face: StairsSectionColor.defaultHex, the app's own section fill.
let cutColor = "#E2E8C1"
let hatchColor = "#10281A"
let planeColor = "#1A5E3A"
let planeLineColor = "#C7E373"

/// The ground, top to bottom. The dark appearance gets a deeper pair.
let ground = ["0.16500,0.42000,0.24000", "0.00800,0.15000,0.08500"]
let groundDark = ["0.07000,0.24000,0.13500", "0.00000,0.06500,0.03500"]

// MARK: Model

// Model units are the same length along every axis: x runs right and down the
// canvas, z left and down, y up. The staircase stands on y = 0 with its back at
// z = 0 and its steps coming down towards the viewer. It is cut off square at
// x = stairWidth, and that end is the hatched face.
let stepCount = 3
let stepRun = 0.9
let stepRise = 0.8
let stairWidth = 2.5

let stairDepth = Double(stepCount) * stepRun
let stairHeight = Double(stepCount) * stepRise

/// How far the work plane reaches past the staircase on every side.
let planeMargin = 0.45
let planeX = (min: -planeMargin, max: stairWidth + planeMargin)
let planeZ = (min: -planeMargin, max: stairDepth + planeMargin)
/// Faint rulings across the plane, at these x.
let planeRulings = (0...3).map { Double($0) * stairWidth / 3 }

/// Step 0 is the tallest, at the back.
func stepHeight(_ step: Int) -> Double {
    Double(stepCount - step) * stepRise
}

func stepBack(_ step: Int) -> Double {
    Double(step) * stepRun
}

func stepFront(_ step: Int) -> Double {
    Double(step + 1) * stepRun
}

// MARK: Projection

let canvas = 1024.0
/// Canvas points a model unit covers sideways along either ground axis.
let unit = 118.0
/// How far a ground axis drops for each point it travels sideways.
let slope = 0.43
/// Canvas points a model unit covers upwards. With this value the three axes
/// are one true view, from 45 degrees round and asin(slope) above.
let rise = unit * (2 * (1 - slope * slope)).squareRoot()

struct Point {
    var x: Double
    var y: Double
}

func flat(_ x: Double, _ y: Double, _ z: Double) -> Point {
    Point(x: (x - z) * unit, y: (x + z) * unit * slope - y * rise)
}

/// Where the model's origin lands so that the drawing sits centred on the canvas.
let origin: Point = {
    let outline = [
        flat(planeX.min, 0, planeZ.min), flat(planeX.max, 0, planeZ.min),
        flat(planeX.max, 0, planeZ.max), flat(planeX.min, 0, planeZ.max),
        flat(0, stairHeight, 0), flat(stairWidth, stairHeight, 0)
    ]
    let xs = outline.map(\.x)
    let ys = outline.map(\.y)
    return Point(
        x: canvas / 2 - (xs.min()! + xs.max()!) / 2,
        y: canvas / 2 - (ys.min()! + ys.max()!) / 2
    )
}()

func project(_ x: Double, _ y: Double, _ z: Double) -> Point {
    let point = flat(x, y, z)
    return Point(x: origin.x + point.x, y: origin.y + point.y)
}

// MARK: Shapes

/// A filled outline, or a line when it is left open.
struct Shape {
    var points: [Point]
    var isClosed = true
    var fill: String?
    var stroke: String?
    var strokeOpacity = 1.0
    var strokeWidth = 0.0
}

/// The part of a polygon where `side` is not negative.
func clip(_ polygon: [Point], _ side: (Point) -> Double) -> [Point] {
    var kept: [Point] = []
    for (index, current) in polygon.enumerated() {
        let previous = polygon[(index + polygon.count - 1) % polygon.count]
        let before = side(previous)
        let after = side(current)
        if (before >= 0) != (after >= 0) {
            let along = before / (before - after)
            kept.append(Point(
                x: previous.x + (current.x - previous.x) * along,
                y: previous.y + (current.y - previous.y) * along
            ))
        }
        if after >= 0 {
            kept.append(current)
        }
    }
    return kept
}

// MARK: Layers

/// The three top faces. Their stroke overlaps the faces below by a hair, so no
/// seam shows between the layers.
func treads() -> [Shape] {
    (0..<stepCount).map { step in
        let height = stepHeight(step)
        return Shape(
            points: [
                project(0, height, stepBack(step)),
                project(stairWidth, height, stepBack(step)),
                project(stairWidth, height, stepFront(step)),
                project(0, height, stepFront(step))
            ],
            fill: treadColor,
            stroke: treadEdgeColor,
            strokeWidth: 6
        )
    }
}

/// The outline of the cut: the staircase's profile, in the plane x = stairWidth.
func profile() -> [Point] {
    var outline = [project(stairWidth, 0, 0)]
    for step in 0..<stepCount {
        outline.append(project(stairWidth, stepHeight(step), stepBack(step)))
        outline.append(project(stairWidth, stepHeight(step), stepFront(step)))
    }
    outline.append(project(stairWidth, 0, stairDepth))
    return outline
}

/// The risers, over a backing the shape of the cut face so that nothing behind
/// the staircase shows through where the Section layer meets them.
func stairBody() -> [Shape] {
    var body = [Shape(points: profile(), fill: sideColor)]
    for step in (0..<stepCount).reversed() {
        let top = stepHeight(step)
        let bottom = top - stepRise
        body.append(Shape(
            points: [
                project(0, top, stepFront(step)),
                project(stairWidth, top, stepFront(step)),
                project(stairWidth, bottom, stepFront(step)),
                project(0, bottom, stepFront(step))
            ],
            fill: riserColor
        ))
    }
    return body
}

/// Stripe width and the distance from one stripe to the next, measured across
/// them.
let hatchWidth = 8.0
let hatchSpacing = 30.0

/// The cut face. As in the app, the hatching runs at 45 degrees on the canvas
/// whatever angle the face is seen from. Each stripe is cut to the outline, so
/// its ends follow the edge.
func section() -> [Shape] {
    let outline = profile()
    var face = [Shape(points: outline, fill: cutColor)]
    // Constant along a stripe, and one per canvas point across the stripes.
    func across(_ point: Point) -> Double {
        (point.x - point.y) / 2.0.squareRoot()
    }
    let reach = outline.map(across)
    var centre = reach.min()! + hatchSpacing / 2
    while centre - hatchWidth / 2 < reach.max()! {
        let low = centre - hatchWidth / 2
        let high = centre + hatchWidth / 2
        let stripe = clip(clip(outline) { across($0) - low }) { high - across($0) }
        if stripe.count >= 3 {
            face.append(Shape(points: stripe, fill: hatchColor))
        }
        centre += hatchSpacing
    }
    return face
}

func plane() -> [Shape] {
    var body = [Shape(
        points: [
            project(planeX.min, 0, planeZ.min),
            project(planeX.max, 0, planeZ.min),
            project(planeX.max, 0, planeZ.max),
            project(planeX.min, 0, planeZ.max)
        ],
        fill: planeColor,
        stroke: planeLineColor,
        strokeOpacity: 0.58,
        strokeWidth: 6
    )]
    for x in planeRulings {
        body.append(Shape(
            points: [project(x, 0, planeZ.min + 0.08), project(x, 0, planeZ.max - 0.08)],
            isClosed: false,
            stroke: planeLineColor,
            strokeOpacity: 0.2,
            strokeWidth: 3
        ))
    }
    return body
}

struct Layer {
    var name: String
    var shapes: [Shape]
    var shadow: String
}

/// Front to back, the order icon.json lists them. Each is a glass piece in its
/// own group, so each catches its own highlight and casts its own shadow.
let layers = [
    Layer(name: "Treads", shapes: treads(), shadow: "0.5"),
    Layer(name: "Section", shapes: section(), shadow: "0.5"),
    Layer(name: "Body", shapes: stairBody(), shadow: "0.5"),
    Layer(name: "Plane", shapes: plane(), shadow: "0.5")
]

// MARK: SVG

func number(_ value: Double) -> String {
    let text = String(format: "%.1f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

func svg(_ shape: Shape) -> String {
    var path = shape.points.enumerated()
        .map { "\($0.offset == 0 ? "M" : "L")\(number($0.element.x)),\(number($0.element.y))" }
        .joined(separator: " ")
    if shape.isClosed {
        path += " Z"
    }
    var element = "<path d=\"\(path)\" fill=\"\(shape.fill ?? "none")\""
    if let stroke = shape.stroke {
        element += " stroke=\"\(stroke)\" stroke-width=\"\(number(shape.strokeWidth))\""
        if shape.strokeOpacity < 1 {
            element += " stroke-opacity=\"\(shape.strokeOpacity)\""
        }
        element += " stroke-linejoin=\"round\" stroke-linecap=\"round\""
    }
    return element + "/>"
}

func svg(_ shapes: [Shape]) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
        + shapes.map { "  \(svg($0))\n" }.joined()
        + "</svg>\n"
}

// MARK: icon.json

func gradient(_ stops: [String], indent: String) -> String {
    """
    \(indent)"linear-gradient" : [
    \(indent)  "extended-srgb:\(stops[0]),1.00000",
    \(indent)  "extended-srgb:\(stops[1]),1.00000"
    \(indent)]
    """
}

// Written by hand in the style Icon Composer saves, keys in alphabetical order.
func iconJSON() -> String {
    let groups = layers.map { layer in
        """
            {
              "layers" : [
                {
                  "image-name" : "\(layer.name).svg",
                  "name" : "\(layer.name)"
                }
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : \(layer.shadow)
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
        """
    }.joined(separator: ",\n")

    return """
    {
      "fill-specializations" : [
        {
          "value" : {
    \(gradient(ground, indent: "        "))
          }
        },
        {
          "appearance" : "dark",
          "value" : {
    \(gradient(groundDark, indent: "        "))
          }
        }
      ],
      "groups" : [
    \(groups)
      ],
      "supported-platforms" : {
        "squares" : "shared"
      }
    }

    """
}

// MARK: visionOS image stack

/// The stack's layers, front to back. The back one has to be opaque.
let stackLayers: [(name: String, shapes: [Shape])] = [
    ("Front", stairBody() + section() + treads()),
    ("Middle", plane()),
    ("Back", [])
]

/// visionOS crops to a circle and slides the layers as the viewer moves, so the
/// drawing is drawn this much smaller about the centre to stay clear of the edge.
let stackScale = 0.88

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ components: [Double], opacity: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: components.map { CGFloat($0) } + [CGFloat(opacity)])!
}

/// "#RRGGBB"
func color(_ hex: String, opacity: Double = 1) -> CGColor {
    let value = Int(hex.dropFirst(), radix: 16)!
    return color([16, 8, 0].map { Double((value >> $0) & 0xFF) / 255 }, opacity: opacity)
}

func draw(_ shape: Shape, in context: CGContext) {
    context.beginPath()
    context.addLines(between: shape.points.map { CGPoint(x: $0.x, y: $0.y) })
    if shape.isClosed {
        context.closePath()
    }
    if let fill = shape.fill {
        context.setFillColor(color(fill))
    }
    if let stroke = shape.stroke {
        context.setStrokeColor(color(stroke, opacity: shape.strokeOpacity))
        context.setLineWidth(shape.strokeWidth)
    }
    switch (shape.fill, shape.stroke) {
    case (.some, .some): context.drawPath(using: .fillStroke)
    case (.some, nil): context.drawPath(using: .fill)
    default: context.drawPath(using: .stroke)
    }
}

/// A 1024 px PNG of the shapes, in the SVGs' coordinates. With no shapes it is
/// the ground alone, full bleed and without an alpha channel.
func png(_ shapes: [Shape]) -> Data {
    let size = Int(canvas)
    let alpha: CGImageAlphaInfo = shapes.isEmpty ? .noneSkipLast : .premultipliedLast
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: alpha.rawValue
    )!
    // y runs down, as it does in an SVG.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    if shapes.isEmpty {
        let stops = ground.map { color($0.split(separator: ",").map { Double($0)! }) }
        let fade = CGGradient(colorsSpace: sRGB, colors: stops as CFArray, locations: [0, 1])!
        context.drawLinearGradient(fade, start: .zero, end: CGPoint(x: 0, y: canvas), options: [])
    } else {
        context.translateBy(x: canvas / 2, y: canvas / 2)
        context.scaleBy(x: stackScale, y: stackScale)
        context.translateBy(x: -canvas / 2, y: -canvas / 2)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for shape in shapes {
            draw(shape, in: context)
        }
    }

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not encode a PNG")
    }
    return data as Data
}

/// An asset catalog Contents.json, in the style Xcode saves.
func contents(_ extra: [String: Any] = [:]) throws -> Data {
    let info: [String: Any] = ["author": "xcode", "version": 1]
    let object = extra.merging(["info": info]) { first, _ in first }
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
}

// MARK: Output

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let iconURL = rootURL.appendingPathComponent("App/Resources/AppIcon.icon", isDirectory: true)
let assetsURL = iconURL.appendingPathComponent("Assets", isDirectory: true)

try? fileManager.removeItem(at: iconURL)
try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)

for layer in layers {
    try svg(layer.shapes).write(
        to: assetsURL.appendingPathComponent("\(layer.name).svg"),
        atomically: true,
        encoding: .utf8
    )
}
try iconJSON().write(to: iconURL.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

print(iconURL.path)

let catalogURL = rootURL.appendingPathComponent("App/Resources/Assets.xcassets", isDirectory: true)
let stackURL = catalogURL.appendingPathComponent("AppIcon.solidimagestack", isDirectory: true)

try? fileManager.removeItem(at: stackURL)
for layer in stackLayers {
    let layerURL = stackURL.appendingPathComponent("\(layer.name).solidimagestacklayer", isDirectory: true)
    let imagesURL = layerURL.appendingPathComponent("Content.imageset", isDirectory: true)
    try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    try contents().write(to: layerURL.appendingPathComponent("Contents.json"))
    try contents(["images": [["filename": "\(layer.name).png", "idiom": "vision", "scale": "2x"]]])
        .write(to: imagesURL.appendingPathComponent("Contents.json"))
    try png(layer.shapes).write(to: imagesURL.appendingPathComponent("\(layer.name).png"))
}
try contents(["layers": stackLayers.map { ["filename": "\($0.name).solidimagestacklayer"] }])
    .write(to: stackURL.appendingPathComponent("Contents.json"))
try contents().write(to: catalogURL.appendingPathComponent("Contents.json"))

print(stackURL.path)
