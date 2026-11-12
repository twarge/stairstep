#!/usr/bin/env swift

// Writes the app icon as an Icon Composer bundle.
//
//     swift scripts/generate_app_icon.swift        (or `make icon`)
//
// The output is App/Resources/AppIcon.icon: icon.json plus one SVG per layer.
// Xcode's asset compiler turns it into every size each platform needs and
// applies the system shape and the glass, dark, clear and tinted treatments,
// so the artwork here is full bleed and carries no mask, rim or shadow of its
// own.
//
// The picture is three steps standing on a work plane, on a green ground. From
// back to front the layers are the ground (the fill in icon.json), Plane, Body
// (risers and the stepped side) and Treads.
//
// The bundle is committed, so this only needs running when the design changes.
// To look at the result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         App/Resources/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Foundation only: no AppKit, so it starts in a second or two.

import Foundation

// MARK: Colours

let treadColor = "#FFF1A4"
let treadEdgeColor = "#FFFCC7"
let riserColor = "#EFC764"
let sideColor = "#B38F3F"
let planeColor = "#1A5E3A"
let planeLineColor = "#C7E373"

/// The ground, top to bottom. The dark appearance gets a deeper pair.
let ground = ["0.16500,0.42000,0.24000", "0.00800,0.15000,0.08500"]
let groundDark = ["0.07000,0.24000,0.13500", "0.00000,0.06500,0.03500"]

// MARK: Model

/// Model units: x runs right and down the canvas, z left and down, y up.
struct Step {
    var back: Double
    var front: Double
    var height: Double
}

/// Back to front, tallest first.
let steps = [
    Step(back: 0.00, front: 0.92, height: 2.46),
    Step(back: 0.92, front: 1.80, height: 1.64),
    Step(back: 1.80, front: 2.68, height: 0.82)
]
let stairLeft = -0.10
let stairRight = 3.20

let planeX = (min: -0.54, max: 3.66)
let planeZ = (min: -0.32, max: 3.10)
/// Faint rulings across the plane, at these x.
let planeRulings = [-0.10, 1.00, 2.10, 3.20]

// MARK: Projection

let canvas = 1024.0
/// Canvas points per model unit along a ground axis, and per unit of height.
let unit = 105.0
let rise = 90.6
/// How far a ground axis drops for each point it travels sideways.
let slope = 0.43

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
        flat(stairLeft, steps[0].height, 0), flat(stairRight, steps[0].height, 0)
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

// MARK: SVG

func number(_ value: Double) -> String {
    let text = String(format: "%.1f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

func points(_ list: [Point]) -> String {
    list.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ")
}

func svg(_ body: [String]) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
        + body.map { "  \($0)\n" }.joined()
        + "</svg>\n"
}

// MARK: Layers

/// The three top faces. Their stroke overlaps the risers below by a hair, so no
/// seam shows between the two layers.
func treads() -> [String] {
    var body = ["<g fill=\"\(treadColor)\" stroke=\"\(treadEdgeColor)\" stroke-width=\"6\" stroke-linejoin=\"round\">"]
    for step in steps {
        let face = [
            project(stairLeft, step.height, step.back),
            project(stairRight, step.height, step.back),
            project(stairRight, step.height, step.front),
            project(stairLeft, step.height, step.front)
        ]
        body.append("  <polygon points=\"\(points(face))\"/>")
    }
    body.append("</g>")
    return body
}

/// The visible part of each riser, and the stepped side as one outline.
func stairBody() -> [String] {
    var profile = [project(stairRight, 0, 0)]
    var body: [String] = []
    var floor = 0.0
    for step in steps.reversed() {
        let riser = [
            project(stairLeft, step.height, step.front),
            project(stairRight, step.height, step.front),
            project(stairRight, floor, step.front),
            project(stairLeft, floor, step.front)
        ]
        body.append("<polygon points=\"\(points(riser))\" fill=\"\(riserColor)\"/>")
        floor = step.height
    }
    for step in steps {
        profile.append(project(stairRight, step.height, step.back))
        profile.append(project(stairRight, step.height, step.front))
    }
    profile.append(project(stairRight, 0, steps[steps.count - 1].front))
    body.insert("<polygon points=\"\(points(profile))\" fill=\"\(sideColor)\"/>", at: 0)
    return body
}

func plane() -> [String] {
    let corners = [
        project(planeX.min, 0, planeZ.min),
        project(planeX.max, 0, planeZ.min),
        project(planeX.max, 0, planeZ.max),
        project(planeX.min, 0, planeZ.max)
    ]
    var body = [
        "<polygon points=\"\(points(corners))\" fill=\"\(planeColor)\" stroke=\"\(planeLineColor)\" "
            + "stroke-opacity=\"0.58\" stroke-width=\"6\" stroke-linejoin=\"round\"/>",
        "<g stroke=\"\(planeLineColor)\" stroke-opacity=\"0.2\" stroke-width=\"3\" stroke-linecap=\"round\">"
    ]
    for x in planeRulings {
        let from = project(x, 0, planeZ.min + 0.08)
        let to = project(x, 0, planeZ.max - 0.10)
        body.append("  <line x1=\"\(number(from.x))\" y1=\"\(number(from.y))\" x2=\"\(number(to.x))\" y2=\"\(number(to.y))\"/>")
    }
    body.append("</g>")
    return body
}

// MARK: icon.json

struct Layer {
    var name: String
    var body: [String]
    var shadow: String
}

/// Front to back, the order icon.json lists them. Each is a glass piece in its
/// own group, so each catches its own highlight and casts its own shadow.
let layers = [
    Layer(name: "Treads", body: treads(), shadow: "0.5"),
    Layer(name: "Body", body: stairBody(), shadow: "0.5"),
    Layer(name: "Plane", body: plane(), shadow: "0.5")
]

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

// MARK: Output

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let iconURL = rootURL.appendingPathComponent("App/Resources/AppIcon.icon", isDirectory: true)
let assetsURL = iconURL.appendingPathComponent("Assets", isDirectory: true)

try? fileManager.removeItem(at: iconURL)
try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)

for layer in layers {
    try svg(layer.body).write(
        to: assetsURL.appendingPathComponent("\(layer.name).svg"),
        atomically: true,
        encoding: .utf8
    )
}
try iconJSON().write(to: iconURL.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

print(iconURL.path)
