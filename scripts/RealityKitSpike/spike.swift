import AppKit
import Metal
import RealityKit

final class Flag: @unchecked Sendable { var done = false }

@MainActor
struct Rig {
    let device: MTLDevice
    let library: MTLLibrary
    let renderer: RealityRenderer
    let cameraEntity: Entity
    let root: Entity
    let width = 400, height = 400

    init() throws {
        device = MTLCreateSystemDefaultDevice()!
        library = try device.makeLibrary(URL: URL(fileURLWithPath: "spike.metallib"))
        renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // Exact colors for pixel verification — tone mapping compresses them
        // (pure red arrives as ~0.55) and would poison every threshold below.
        renderer.cameraSettings.isToneMappingEnabled = false

        root = Entity()
        cameraEntity = Entity()
        cameraEntity.components.set(PerspectiveCameraComponent(near: 0.01, far: 200, fieldOfViewInDegrees: 48))
        root.addChild(cameraEntity)
        renderer.entities.append(root)
        renderer.activeCamera = cameraEntity
    }

    func placeCamera(z: Float) {
        cameraEntity.look(at: .zero, from: [0, 0, z], relativeTo: nil)
    }

    func render(frames: Int = 3) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let texture = device.makeTexture(descriptor: desc)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))

        for _ in 0..<frames {
            let flag = Flag()
            try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: output, onComplete: { _ in
                flag.done = true
            })
            while !flag.done {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    // BGRA sample helpers
    static func rgb(_ b: [UInt8], _ x: Int, _ y: Int, width: Int) -> (r: Int, g: Int, bch: Int) {
        let i = (y * width + x) * 4
        return (Int(b[i + 2]), Int(b[i + 1]), Int(b[i]))
    }
}

@main
@MainActor
struct Spike {
    static func main() {
        do { try run() } catch {
            print("SPIKE HARNESS ERROR: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        var failures = 0
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            print("  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")  \(detail)")
        }

        // A. Baseline: unlit red box renders offscreen and reads back.
        do {
            let rig = try Rig()
            let box = ModelEntity(mesh: .generateBox(size: 1.0),
                                  materials: [UnlitMaterial(color: .red)])
            rig.root.addChild(box)
            rig.placeCamera(z: 2.2)
            let px = try rig.render()
            var red = 0
            for y in stride(from: 0, to: 400, by: 4) {
                for x in stride(from: 0, to: 400, by: 4) {
                    let c = Rig.rgb(px, x, y, width: 400)
                    if c.r > 180 && c.g < 80 && c.bch < 80 { red += 1 }
                }
            }
            if red <= 200 {
                var hist = [String: Int]()
                for y in stride(from: 0, to: 400, by: 8) {
                    for x in stride(from: 0, to: 400, by: 8) {
                        let c = Rig.rgb(px, x, y, width: 400)
                        hist["\(c.r/32)-\(c.g/32)-\(c.bch/32)", default: 0] += 1
                    }
                }
                print("    A histogram:", hist.sorted { $0.value > $1.value }.prefix(5))
            }
            report("A offscreen baseline", red > 200, "red samples \(red)/10000")
        }

        // B. CustomMaterial clip: keep x <= 0. Camera on +Z: kept half projects LEFT.
        do {
            let rig = try Rig()
            var material = try CustomMaterial(
                surfaceShader: .init(named: "clipSurface", in: rig.library),
                geometryModifier: .init(named: "passGeometry", in: rig.library),
                lightingModel: .unlit)
            material.custom.value = SIMD4<Float>(1, 0, 0, 0)
            let box = ModelEntity(mesh: .generateBox(size: 1.4), materials: [material])
            rig.root.addChild(box)
            rig.placeCamera(z: 2.6)
            let px = try rig.render()
            var leftGreen = 0, rightGreen = 0
            for y in stride(from: 0, to: 400, by: 2) {
                for x in stride(from: 0, to: 400, by: 2) {
                    let c = Rig.rgb(px, x, y, width: 400)
                    let isGreen = c.g > 150 && c.r < 120 && c.bch < 120
                    if isGreen { if x < 195 { leftGreen += 1 } else if x > 205 { rightGreen += 1 } }
                }
            }
            report("B section clip (discard)", leftGreen > 300 && rightGreen < 20,
                   "kept-side \(leftGreen), cut-side \(rightGreen)")
        }

        // C. Screen-space hatch: stripe period constant across camera distance.
        do {
            func period(atCameraZ z: Float) throws -> Double {
                let rig = try Rig()
                var material = try CustomMaterial(
                    surfaceShader: .init(named: "hatchSurface", in: rig.library),
                    geometryModifier: .init(named: "passGeometry", in: rig.library),
                    lightingModel: .unlit)
                material.custom.value = SIMD4<Float>(Float(rig.width), Float(rig.height), 12, 2)
                let plane = ModelEntity(mesh: .generatePlane(width: 40, height: 40), materials: [material])
                rig.root.addChild(plane)
                rig.placeCamera(z: z)
                let px = try rig.render()
                var isLine = [Bool]()
                for x in 0..<400 {
                    let c = Rig.rgb(px, x, 200, width: 400)
                    isLine.append(c.r < 90 && c.g < 90)
                }
                var centers = [Double](); var start: Int? = nil
                for (x, v) in isLine.enumerated() {
                    if v && start == nil { start = x }
                    if !v, let s = start { centers.append(Double(s + x - 1) / 2); start = nil }
                }
                guard centers.count >= 4 else { return 0 }
                let mid = centers.dropFirst().dropLast()
                var deltas = [Double]()
                var previous: Double? = nil
                for c in mid { if let p = previous { deltas.append(c - p) }; previous = c }
                return deltas.reduce(0, +) / Double(deltas.count)
            }
            let near = try period(atCameraZ: 3)
            let far = try period(atCameraZ: 9)
            let expected = 12.0 * 2.0.squareRoot()
            let ok = abs(near - expected) < 1.2 && abs(far - expected) < 1.2
            report("C hatch zoom invariance", ok,
                   String(format: "period near %.2f / far %.2f px (expect %.2f)", near, far, expected))
        }

        // D. Wireframe via LowLevelMesh line topology: cube edges only.
        do {
            let rig = try Rig()
            var descriptor = LowLevelMesh.Descriptor()
            descriptor.vertexAttributes = [
                .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0)
            ]
            descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
            descriptor.vertexCapacity = 8
            descriptor.indexCapacity = 24
            descriptor.indexType = .uint32
            let mesh = try LowLevelMesh(descriptor: descriptor)

            let h: Float = 0.7
            let corners: [SIMD3<Float>] = [
                [-h, -h, -h], [h, -h, -h], [h, h, -h], [-h, h, -h],
                [-h, -h, h], [h, -h, h], [h, h, h], [-h, h, h],
            ]
            let edges: [UInt32] = [0,1, 1,2, 2,3, 3,0, 4,5, 5,6, 6,7, 7,4, 0,4, 1,5, 2,6, 3,7]
            mesh.withUnsafeMutableBytes(bufferIndex: 0) { buffer in
                buffer.bindMemory(to: SIMD3<Float>.self).update(fromContentsOf: corners)
            }
            mesh.withUnsafeMutableIndices { buffer in
                buffer.bindMemory(to: UInt32.self).update(fromContentsOf: edges)
            }
            mesh.parts.append(LowLevelMesh.Part(
                indexOffset: 0, indexCount: 24, topology: .line, materialIndex: 0,
                bounds: BoundingBox(min: [-h, -h, -h], max: [h, h, h])))

            let resource = try MeshResource(from: mesh)
            let entity = ModelEntity(mesh: resource, materials: [UnlitMaterial(color: .white)])
            entity.orientation = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
            rig.root.addChild(entity)
            rig.placeCamera(z: 3)
            let px = try rig.render()
            var white = 0, total = 0
            for y in 0..<400 {
                for x in 0..<400 {
                    let c = Rig.rgb(px, x, y, width: 400)
                    total += 1
                    if c.r > 200 && c.g > 200 && c.bch > 200 { white += 1 }
                }
            }
            let coverage = Double(white) / Double(total)
            report("D wireframe (line topology)", white > 300 && coverage < 0.10,
                   String(format: "white px %d, coverage %.1f%% (lines, not fill)", white, coverage * 100))
        }

        print(failures == 0 ? "\nALL SPIKES PASS" : "\n\(failures) SPIKE(S) FAILED")
        exit(failures == 0 ? 0 : 2)
    }
}
