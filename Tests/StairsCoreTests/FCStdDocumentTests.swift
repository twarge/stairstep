import Foundation
import Testing
import simd
@testable import StairsCore

// MARK: - Fixture plumbing

/// Builds a stored (uncompressed) zip from named entries — enough of the format
/// for `ZipArchive` to open, so tests can synthesize `.FCStd` documents without
/// binary fixtures in the repo.
private func storedZip(_ entries: [(name: String, payload: Data)]) -> Data {
    var out = Data()
    var directory = Data()

    func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    for entry in entries {
        let name = Data(entry.name.utf8)
        let offset = UInt32(out.count)

        appendLE(UInt32(0x0403_4b50), to: &out)
        appendLE(UInt16(20), to: &out)                      // version needed
        appendLE(UInt16(0), to: &out)                       // flags
        appendLE(UInt16(0), to: &out)                       // method: stored
        appendLE(UInt32(0), to: &out)                       // time + date
        appendLE(UInt32(0), to: &out)                       // crc (unchecked)
        appendLE(UInt32(entry.payload.count), to: &out)     // compressed
        appendLE(UInt32(entry.payload.count), to: &out)     // uncompressed
        appendLE(UInt16(name.count), to: &out)
        appendLE(UInt16(0), to: &out)                       // extra
        out.append(name)
        out.append(entry.payload)

        appendLE(UInt32(0x0201_4b50), to: &directory)
        appendLE(UInt16(20), to: &directory)                // made by
        appendLE(UInt16(20), to: &directory)                // needed
        appendLE(UInt16(0), to: &directory)                 // flags
        appendLE(UInt16(0), to: &directory)                 // method
        appendLE(UInt32(0), to: &directory)                 // time + date
        appendLE(UInt32(0), to: &directory)                 // crc
        appendLE(UInt32(entry.payload.count), to: &directory)
        appendLE(UInt32(entry.payload.count), to: &directory)
        appendLE(UInt16(name.count), to: &directory)
        appendLE(UInt16(0), to: &directory)                 // extra
        appendLE(UInt16(0), to: &directory)                 // comment
        appendLE(UInt16(0), to: &directory)                 // disk
        appendLE(UInt16(0), to: &directory)                 // internal attrs
        appendLE(UInt32(0), to: &directory)                 // external attrs
        appendLE(UInt32(offset), to: &directory)
        directory.append(name)
    }

    let directoryOffset = UInt32(out.count)
    out.append(directory)
    appendLE(UInt32(0x0605_4b50), to: &out)
    appendLE(UInt16(0), to: &out)                           // disk
    appendLE(UInt16(0), to: &out)                           // directory disk
    appendLE(UInt16(entries.count), to: &out)               // entries on disk
    appendLE(UInt16(entries.count), to: &out)               // entries total
    appendLE(UInt32(directory.count), to: &out)
    appendLE(directoryOffset, to: &out)
    appendLE(UInt16(0), to: &out)                           // comment
    return out
}

private func fcstd(documentXML: String, extraEntries: [(name: String, payload: Data)] = []) -> Data {
    storedZip([("Document.xml", Data(documentXML.utf8))] + extraEntries)
}

/// A placeholder BREP payload — the reader only checks that the entry exists
/// and is non-empty; nothing in these tests reaches OpenCascade.
private let stubShape = Data("x".utf8)

private func doubleLE(_ value: Double) -> Data {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) }
}

private func expectPosition(
    _ placement: FCStdPlacement?,
    _ expected: SIMD3<Double>,
    accuracy: Double = 1e-9,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let position = placement?.position ?? .zero
    #expect(
        simd_length(position - expected) < accuracy,
        "expected \(expected), got \(position)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Placement algebra

@Suite struct FCStdPlacementTests {
    @Test func composesRotationThenTranslation() {
        // 90° about Z at the origin, then translated: rotating (1,0,0) lands on
        // (0,1,0) before the offset applies.
        let halfAngle = Double.pi / 4
        let rotate = FCStdPlacement(
            rotation: SIMD4(0, 0, sin(halfAngle), cos(halfAngle)),
            position: .zero
        )
        let translate = FCStdPlacement(rotation: SIMD4(0, 0, 0, 1), position: SIMD3(10, 0, 0))

        let combined = translate * rotate
        let point = combined.quaternion.act(SIMD3(1, 0, 0)) + combined.position
        #expect(simd_length(point - SIMD3(10, 1, 0)) < 1e-9)
    }

    @Test func inverseCancels() {
        let placement = FCStdPlacement(
            rotation: SIMD4(0.5, 0.5, 0.5, 0.5),
            position: SIMD3(3, -2, 7)
        )
        let identity = placement * placement.inverse
        #expect(identity.isIdentity)
    }

    @Test func normalizesDriftedQuaternions() {
        let placement = FCStdPlacement(rotation: SIMD4(0, 0, 0, 2), position: .zero)
        #expect(placement.isIdentity)
    }
}

// MARK: - Colour decoding

@Suite struct FCStdColorListTests {
    @Test func decodesPackedColors() {
        var data = Data()
        data.append(contentsOf: [3, 0, 0, 0]) // count, little-endian
        // 0xRRGGBBAA packed values, stored little-endian.
        for packed in [UInt32(0xFF00_0000), 0x00FF_0000, 0x0000_FF00] {
            withUnsafeBytes(of: packed.littleEndian) { data.append(contentsOf: $0) }
        }

        let colors = FCStdAppearance.decodeColorList(data)
        #expect(colors == [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
    }

    @Test func rejectsTruncatedLists() {
        var data = Data()
        data.append(contentsOf: [2, 0, 0, 0])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // one colour, not two
        #expect(FCStdAppearance.decodeColorList(data) == nil)
    }
}

// MARK: - Instance resolution

@Suite struct FCStdInstanceTests {
    @Test func partPlacementReachesMembersAndHiddenShapesAreCounted() throws {
        let xml = """
        <?xml version="1.0"?>
        <Document SchemaVersion="4">
        <Objects Count="4">
        <Object type="Part::Feature" name="Plain" id="1" />
        <Object type="Part::Feature" name="Hidden" id="2" />
        <Object type="App::Part" name="Group" id="3" />
        <Object type="Part::Feature" name="Member" id="4" />
        </Objects>
        <ObjectData Count="4">
        <Object name="Plain">
        <Properties Count="2">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape.brp"/></Property>
        <Property name="Label" type="App::PropertyString"><String value="Plain Part"/></Property>
        </Properties>
        </Object>
        <Object name="Hidden">
        <Properties Count="2">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape1.brp"/></Property>
        <Property name="Visibility" type="App::PropertyBool"><Bool value="false"/></Property>
        </Properties>
        </Object>
        <Object name="Group">
        <Properties Count="2">
        <Property name="Group" type="App::PropertyLinkList"><LinkList count="1"><Link value="Member"/></LinkList></Property>
        <Property name="Placement" type="App::PropertyPlacement"><PropertyPlacement Px="10" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        </Properties>
        </Object>
        <Object name="Member">
        <Properties Count="1">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape2.brp"/></Property>
        </Properties>
        </Object>
        </ObjectData>
        </Document>
        """
        let document = try FCStdDocument(data: fcstd(documentXML: xml, extraEntries: [
            ("PartShape.brp", stubShape),
            ("PartShape1.brp", stubShape),
            ("PartShape2.brp", stubShape)
        ]))

        #expect(document.instances.count == 2)
        #expect(document.hiddenShapeCount == 1)

        let plain = try #require(document.instances.first { $0.objectName == "Plain" })
        #expect(plain.label == "Plain Part")
        #expect(plain.placement == nil)

        let member = try #require(document.instances.first { $0.objectName == "Member" })
        expectPosition(member.placement, SIMD3(10, 0, 0))
    }

    @Test func linksPlaceRepeatAndOverrideTheirTargets() throws {
        // Box sits at (5,0,0) — baked into its stored payload — and is hidden,
        // as assemblies usually keep their base parts.
        // LinkA overrides that placement (LinkTransform false), LinkB keeps it,
        // LinkC is a two-element array whose second element is hidden, and
        // External points at another document.
        let xml = """
        <?xml version="1.0"?>
        <Document SchemaVersion="4">
        <Objects Count="5">
        <Object type="Part::Feature" name="Box" id="1" />
        <Object type="App::Link" name="LinkA" id="2" />
        <Object type="App::Link" name="LinkB" id="3" />
        <Object type="App::Link" name="LinkC" id="4" />
        <Object type="App::Link" name="External" id="5" />
        </Objects>
        <ObjectData Count="5">
        <Object name="Box">
        <Properties Count="3">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape.brp"/></Property>
        <Property name="Placement" type="App::PropertyPlacement"><PropertyPlacement Px="5" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        <Property name="Visibility" type="App::PropertyBool"><Bool value="false"/></Property>
        </Properties>
        </Object>
        <Object name="LinkA">
        <Properties Count="2">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="" stamp="" name="Box"/></Property>
        <Property name="LinkPlacement" type="App::PropertyPlacement"><PropertyPlacement Px="0" Py="20" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        </Properties>
        </Object>
        <Object name="LinkB">
        <Properties Count="3">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="" stamp="" name="Box"/></Property>
        <Property name="LinkPlacement" type="App::PropertyPlacement"><PropertyPlacement Px="0" Py="0" Pz="7" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        <Property name="LinkTransform" type="App::PropertyBool"><Bool value="true"/></Property>
        </Properties>
        </Object>
        <Object name="LinkC">
        <Properties Count="4">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="" stamp="" name="Box"/></Property>
        <Property name="ElementCount" type="App::PropertyIntegerConstraint"><Integer value="2"/></Property>
        <Property name="PlacementList" type="App::PropertyPlacementList"><PlacementList file="PlacementList"/></Property>
        <Property name="VisibilityList" type="App::PropertyBoolList"><BoolList value="01"/></Property>
        </Properties>
        </Object>
        <Object name="External">
        <Properties Count="1">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="Other.FCStd" stamp="" name="Box"/></Property>
        </Properties>
        </Object>
        </ObjectData>
        </Document>
        """

        // PlacementList doc-file: count, then position x,y,z + quaternion
        // x,y,z,w per element, as doubles.
        var placementList = Data([2, 0, 0, 0])
        for values in [[0.0, 0, 0, 0, 0, 0, 1], [0.0, 100, 0, 0, 0, 0, 1]] {
            for value in values {
                placementList.append(doubleLE(value))
            }
        }

        let document = try FCStdDocument(data: fcstd(documentXML: xml, extraEntries: [
            ("PartShape.brp", stubShape),
            ("PlacementList", placementList)
        ]))

        // LinkA, LinkB, and the first LinkC element; Box itself is hidden.
        #expect(document.instances.count == 3)
        // Box, plus LinkC's second element.
        #expect(document.hiddenShapeCount == 2)
        #expect(document.warnings.count == 1)
        #expect(document.warnings[0].contains("Other.FCStd"))

        let linkA = try #require(document.instances.first { $0.label == "LinkA" })
        #expect(linkA.objectName == "Box")
        // LinkPlacement replaces the baked (5,0,0): (0,20,0) ∘ (-5,0,0).
        expectPosition(linkA.placement, SIMD3(-5, 20, 0))

        let linkB = try #require(document.instances.first { $0.label == "LinkB" })
        // LinkTransform keeps the baked placement; only the link's own applies.
        expectPosition(linkB.placement, SIMD3(0, 0, 7))

        let element = try #require(document.instances.first { $0.label == "LinkC [0]" })
        // Element placement is identity; the override still strips the baked
        // (5,0,0). The second element is hidden by the (reversed) bitset.
        expectPosition(element.placement, SIMD3(-5, 0, 0))
        #expect(!document.instances.contains { $0.label == "LinkC [1]" })
    }

    @Test func linkToPartExpandsMembersInTheGroupFrame() throws {
        let xml = """
        <?xml version="1.0"?>
        <Document SchemaVersion="4">
        <Objects Count="4">
        <Object type="App::Part" name="Asm" id="1" />
        <Object type="Part::Feature" name="Member" id="2" />
        <Object type="App::Link" name="Override" id="3" />
        <Object type="App::Link" name="Compose" id="4" />
        </Objects>
        <ObjectData Count="4">
        <Object name="Asm">
        <Properties Count="3">
        <Property name="Group" type="App::PropertyLinkList"><LinkList count="1"><Link value="Member"/></LinkList></Property>
        <Property name="Placement" type="App::PropertyPlacement"><PropertyPlacement Px="0" Py="0" Pz="3" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        <Property name="Visibility" type="App::PropertyBool"><Bool value="false"/></Property>
        </Properties>
        </Object>
        <Object name="Member">
        <Properties Count="1">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape.brp"/></Property>
        </Properties>
        </Object>
        <Object name="Override">
        <Properties Count="2">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="" stamp="" name="Asm"/></Property>
        <Property name="LinkPlacement" type="App::PropertyPlacement"><PropertyPlacement Px="1" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        </Properties>
        </Object>
        <Object name="Compose">
        <Properties Count="3">
        <Property name="LinkedObject" type="App::PropertyXLink"><XLink file="" stamp="" name="Asm"/></Property>
        <Property name="LinkPlacement" type="App::PropertyPlacement"><PropertyPlacement Px="1" Py="0" Pz="0" Q0="0" Q1="0" Q2="0" Q3="1"/></Property>
        <Property name="LinkTransform" type="App::PropertyBool"><Bool value="true"/></Property>
        </Properties>
        </Object>
        </ObjectData>
        </Document>
        """
        let document = try FCStdDocument(data: fcstd(documentXML: xml, extraEntries: [
            ("PartShape.brp", stubShape)
        ]))

        // Member draws under both links; it also draws on its own (visible,
        // inside a visible-content part) in the part's frame.
        let overridden = try #require(document.instances.first { $0.label.hasPrefix("Override") })
        // LinkTransform false: the link's placement replaces the part's (0,0,3).
        expectPosition(overridden.placement, SIMD3(1, 0, 0))

        let composed = try #require(document.instances.first { $0.label.hasPrefix("Compose") })
        // LinkTransform true: the part's placement survives under the link's.
        expectPosition(composed.placement, SIMD3(1, 0, 3))
    }
}

// MARK: - Real documents (opt-in)

/// Full-pipeline smoke test over real FreeCAD documents. Point
/// `STAIRS_FCSTD_SMOKE_DIR` at a directory of `.FCStd` files to enable; the
/// suite walks it recursively and requires every document to tessellate through
/// OpenCascade (not the extents fallback).
@Suite struct FCStdRealDocumentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STAIRS_FCSTD_SMOKE_DIR"] != nil))
    func importsEveryDocumentInSmokeDirectory() throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["STAIRS_FCSTD_SMOKE_DIR"] ?? "",
            isDirectory: true
        )
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var documents = [URL]()
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "fcstd" {
                documents.append(url)
            }
        }
        try #require(!documents.isEmpty, "no .FCStd files under \(root.path)")

        var failures = [String]()
        for url in documents.sorted(by: { $0.path < $1.path }) {
            do {
                let data = try Data(contentsOf: url)
                let document = try FCStdDocument(data: data)
                let model = try StepMeshImporter.load(data: data, fileName: url.lastPathComponent)
                guard model.importMode == .openCascadeMesh, let mesh = model.mesh else {
                    failures.append("\(url.lastPathComponent): fell back to extents")
                    continue
                }
                print(
                    "✓ \(url.lastPathComponent): \(document.instances.count) instance(s), "
                    + "\(mesh.vertices.count) vertices, \(mesh.materialCount) colour(s), "
                    + "\(model.warnings.count) warning(s)"
                    + (model.warnings.isEmpty ? "" : " — \(model.warnings.joined(separator: " | "))")
                )
                for instance in document.instances.prefix(8) {
                    let position = instance.placement?.position ?? .zero
                    print("    \(instance.label) [\(instance.objectName)] at \(position)")
                }
            } catch StepImportError.unreachableContent(let reason) {
                // Assemblies whose parts all live in other files cannot draw
                // from a single document's bytes; the reader says so.
                print("– \(url.lastPathComponent): skipped — \(reason)")
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// End-to-end per-face colours: borrows a real BREP payload from the first
    /// smoke document, repacks it with a two-colour DiffuseColor list, and
    /// checks both colours reach the tessellated mesh.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STAIRS_FCSTD_SMOKE_DIR"] != nil))
    func perFaceColorsReachTheMesh() throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["STAIRS_FCSTD_SMOKE_DIR"] ?? "",
            isDirectory: true
        )
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var payload: Data?
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "fcstd",
                  let data = try? Data(contentsOf: url),
                  let document = try? FCStdDocument(data: data),
                  let first = document.instances.first,
                  let brep = document.payloadsByEntry()[first.entryName] else {
                continue
            }
            payload = brep
            break
        }
        let brep = try #require(payload, "no usable BREP payload under \(root.path)")

        let xml = """
        <?xml version="1.0"?>
        <Document SchemaVersion="4">
        <Objects Count="1">
        <Object type="Part::Feature" name="Solid" id="1" />
        </Objects>
        <ObjectData Count="1">
        <Object name="Solid">
        <Properties Count="1">
        <Property name="Shape" type="Part::PropertyPartShape"><Part file="PartShape.brp"/></Property>
        </Properties>
        </Object>
        </ObjectData>
        </Document>
        """
        let gui = """
        <?xml version="1.0"?>
        <Document SchemaVersion="1">
        <ViewProviderData Count="1">
        <ViewProvider name="Solid" expanded="0">
        <Properties Count="1">
        <Property name="DiffuseColor" type="App::PropertyColorList"><ColorList file="DiffuseColor"/></Property>
        </Properties>
        </ViewProvider>
        </ViewProviderData>
        </Document>
        """
        // First face red, every other face green.
        var diffuse = Data([2, 0, 0, 0])
        for packed in [UInt32(0xFF00_0000), 0x00FF_0000] {
            withUnsafeBytes(of: packed.littleEndian) { diffuse.append(contentsOf: $0) }
        }

        let repacked = storedZip([
            ("Document.xml", Data(xml.utf8)),
            ("PartShape.brp", brep),
            ("GuiDocument.xml", Data(gui.utf8)),
            ("DiffuseColor", diffuse)
        ])
        let model = try StepMeshImporter.load(data: repacked, fileName: "synthetic.FCStd")
        let mesh = try #require(model.mesh)
        let colors = Set(mesh.vertices.map { $0.color })
        #expect(colors.contains { $0.x > 0.9 && $0.y < 0.1 }, "no red face in \(colors)")
        #expect(colors.contains { $0.y > 0.9 && $0.x < 0.1 }, "no green faces in \(colors)")
    }
}

// MARK: - Appearance

@Suite struct FCStdAppearanceTests {
    @Test func readsShapeAndFaceColors() {
        let gui = """
        <?xml version="1.0"?>
        <Document SchemaVersion="1">
        <ViewProviderData Count="2">
        <ViewProvider name="Plain" expanded="0">
        <Properties Count="2">
        <Property name="ShapeColor" type="App::PropertyColor"><PropertyColor value="4278190335"/></Property>
        <Property name="DiffuseColor" type="App::PropertyColorList"><ColorList file="DiffuseColor"/></Property>
        </Properties>
        </ViewProvider>
        <ViewProvider name="Uniform" expanded="0">
        <Properties Count="1">
        <Property name="DiffuseColor" type="App::PropertyColorList"><ColorList file="DiffuseColor1"/></Property>
        </Properties>
        </ViewProvider>
        </ViewProviderData>
        </Document>
        """

        var faceColors = Data([2, 0, 0, 0])
        for packed in [UInt32(0xFF00_0000), 0x00FF_0000] {
            withUnsafeBytes(of: packed.littleEndian) { faceColors.append(contentsOf: $0) }
        }
        var uniform = Data([1, 0, 0, 0])
        withUnsafeBytes(of: UInt32(0x0000_FF00).littleEndian) { uniform.append(contentsOf: $0) }

        let archive = try! ZipArchive(data: storedZip([
            ("GuiDocument.xml", Data(gui.utf8)),
            ("DiffuseColor", faceColors),
            ("DiffuseColor1", uniform)
        ]))
        let colors = FCStdAppearance.colors(in: archive)

        // 4278190335 = 0xFF0000FF: red with the alpha byte set.
        #expect(colors.shape["Plain"] == SIMD3(1, 0, 0))
        #expect(colors.faces["Plain"] == [SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        // A single-entry list is a whole-shape colour, not a face override.
        #expect(colors.faces["Uniform"] == nil)
    }
}
