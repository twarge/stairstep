import Foundation
import simd

/// A FreeCAD placement: a rotation followed by a translation, matching
/// `Base::Placement`. Stored as FreeCAD serializes it — quaternion (x, y, z, w)
/// and position — so `Document.xml` values pass straight through.
public struct FCStdPlacement: Sendable, Equatable {
    /// Unit quaternion as (x, y, z, w), FreeCAD's `Q0…Q3` order.
    public var rotation: SIMD4<Double>
    public var position: SIMD3<Double>

    public static let identity = FCStdPlacement(rotation: SIMD4(0, 0, 0, 1), position: .zero)

    public init(rotation: SIMD4<Double>, position: SIMD3<Double>) {
        // Normalize defensively: the composition math below assumes a unit
        // quaternion, and XML round-trips through decimal strings drift.
        let length = simd_length(rotation)
        self.rotation = length > 1e-12 ? rotation / length : SIMD4(0, 0, 0, 1)
        self.position = position
    }

    public var isIdentity: Bool {
        self == .identity
    }

    var quaternion: simd_quatd {
        simd_quatd(vector: rotation)
    }

    /// Matrix-style composition: `(a * b)` transforms by `b`, then by `a`.
    public static func * (lhs: FCStdPlacement, rhs: FCStdPlacement) -> FCStdPlacement {
        FCStdPlacement(
            rotation: (lhs.quaternion * rhs.quaternion).vector,
            position: lhs.quaternion.act(rhs.position) + lhs.position
        )
    }

    public var inverse: FCStdPlacement {
        let inverseRotation = quaternion.conjugate
        return FCStdPlacement(
            rotation: inverseRotation.vector,
            position: -inverseRotation.act(position)
        )
    }
}

/// Reads the parts of a FreeCAD `.FCStd` document this app needs to draw it.
///
/// An `.FCStd` is a zip holding `Document.xml` (the object graph and every
/// property) plus one OpenCascade BREP file per shape-bearing object, named
/// `PartShape*.brp`. Rather than importing every BREP — a PartDesign body stores
/// each intermediate feature alongside its final solid, so that would draw the
/// same part several times over — this walks `Document.xml` and keeps only the
/// objects FreeCAD itself would show, resolved into placed *instances*:
///
/// - A stored shape carries its own `Placement` baked into the BREP (FreeCAD
///   syncs the property into the shape's location on save), so a plain object
///   needs no extra transform — unless it sits inside an `App::Part`, whose
///   placement FreeCAD applies in the scenegraph, not the stored geometry.
/// - An `App::Link` stores no geometry at all; it references another object and
///   repositions it. `LinkTransform` decides whether the target's own placement
///   is kept (compose on top) or replaced (strip it via its inverse, since it is
///   baked into the payload). Element arrays repeat the target once per entry of
///   `PlacementList`.
///
/// This is a reader, not a document model: no parametric history, no recompute.
/// It is enough to render what the file already contains.
public struct FCStdDocument: Sendable {
    /// One drawn occurrence of a stored shape. The same zip entry can appear in
    /// several instances (a link array draws one payload many times).
    public struct Instance: Sendable {
        /// The shape-bearing object's internal name, e.g. `Body012` — the key
        /// display colours are stored under.
        public let objectName: String
        /// The user-facing label of whatever the user sees — the link's label
        /// for linked instances, else the object's own.
        public let label: String
        /// Zip entry holding the BREP payload.
        public let entryName: String
        /// Extra rigid transform to apply on top of the stored shape, or `nil`
        /// for the payload as saved.
        public let placement: FCStdPlacement?
    }

    public enum Error: Swift.Error, LocalizedError {
        case missingDocumentXML
        case noVisibleShapes

        public var errorDescription: String? {
            switch self {
            case .missingDocumentXML:
                "The FreeCAD document has no Document.xml, so it is not a valid .FCStd file."
            case .noVisibleShapes:
                "The FreeCAD document contains no visible shapes to display."
            }
        }
    }

    let archive: ZipArchive

    /// Drawn instances in document order.
    public let instances: [Instance]
    /// Geometry-bearing objects (and link elements) hidden in the saved
    /// document. Kept for reporting — a document that is entirely hidden should
    /// say so rather than look empty.
    public let hiddenShapeCount: Int
    /// Things the reader recognized but cannot draw, phrased for the user —
    /// external links, scaled links.
    public let warnings: [String]

    public init(data: Data) throws {
        let archive = try ZipArchive(data: data)
        guard let documentXML = try archive.contents(ofEntryNamed: "Document.xml") else {
            throw Error.missingDocumentXML
        }

        let objects = FCStdManifestParser.parse(documentXML)
        var resolver = FCStdInstanceResolver(objects: objects, archive: archive)
        resolver.resolve()

        self.archive = archive
        self.instances = resolver.instances
        self.hiddenShapeCount = resolver.hiddenShapeCount
        self.warnings = resolver.warnings

        if instances.isEmpty {
            throw Error.noVisibleShapes
        }
    }

    /// Inflates each referenced BREP payload once, keyed by zip entry name.
    /// Entries that fail to inflate are omitted rather than failing the whole
    /// document; callers drop the instances that point at them.
    public func payloadsByEntry() -> [String: Data] {
        var payloads = [String: Data]()
        for instance in instances where payloads[instance.entryName] == nil {
            guard let entry = archive.entry(named: instance.entryName),
                  let data = try? archive.contents(of: entry) else {
                continue
            }
            payloads[instance.entryName] = data
        }
        return payloads
    }
}

// MARK: - Instance resolution

/// Turns the parsed object list into placed instances: applies `App::Part`
/// transforms to plain geometry and expands `App::Link`s (chains, arrays, and
/// links to whole `App::Part` groups) into copies of their targets' payloads.
private struct FCStdInstanceResolver {
    let objects: [FCStdObject]
    let archive: ZipArchive

    var instances = [FCStdDocument.Instance]()
    var hiddenShapeCount = 0
    var warnings = [String]()

    private var byName = [String: FCStdObject]()
    /// Child name → enclosing `App::Part`. Only `App::Part` is a transforming
    /// group: a PartDesign body owns its features' geometry outright (handled by
    /// container ownership below), and a plain group moves nothing.
    private var partParent = [String: String]()
    /// Element name → the array link (`ShowElement` mode) or link group that
    /// claims it; the parent's own placement prefixes every element.
    private var elementParent = [String: String]()
    private var ownedByContainer = Set<String>()
    /// Recursion guard for link chains and nested groups. Real documents nest a
    /// handful deep; cycles would otherwise hang the reader.
    private let maxDepth = 8

    init(objects: [FCStdObject], archive: ZipArchive) {
        self.objects = objects
        self.archive = archive

        for object in objects {
            if byName[object.name] == nil {
                byName[object.name] = object
            }
            if object.typeName == "App::Part" {
                for child in object.groupChildren {
                    partParent[child] = object.name
                }
            }
            for element in object.elementChildren {
                elementParent[element] = object.name
            }
        }

        // A container that has a shape of its own owns its members' geometry: a
        // PartDesign body's shape *is* the result of the features inside it, and
        // FreeCAD marks both the body and its tip visible. Drawing both draws
        // the same solid twice. An App::Part is the other case — it groups
        // objects but has no shape, so its members are the model and must be
        // kept.
        ownedByContainer = Set(
            objects
                .filter { $0.shapeFile != nil }
                .flatMap(\.groupChildren)
        )
    }

    mutating func resolve() {
        var visibleBase = [FCStdDocument.Instance]()
        var allBase = [FCStdDocument.Instance]()
        var linkInstances = [FCStdDocument.Instance]()

        for object in objects {
            if object.linkedObjectName != nil || !object.linkedFile.isEmpty {
                resolveLink(object, into: &linkInstances)
                continue
            }

            guard object.shapeFile != nil, !ownedByContainer.contains(object.name) else {
                continue
            }
            guard let instance = shapeInstance(
                target: object,
                label: object.displayLabel,
                placement: groupTransform(of: object.name)
            ) else {
                continue
            }
            allBase.append(instance)
            if object.isVisible {
                visibleBase.append(instance)
            } else {
                hiddenShapeCount += 1
            }
        }

        // A document whose objects are all hidden still has geometry worth
        // showing; falling back beats presenting an empty viewport.
        if visibleBase.isEmpty && linkInstances.isEmpty {
            instances = allBase
        } else {
            instances = visibleBase + linkInstances
        }
    }

    // MARK: Links

    private mutating func resolveLink(_ link: FCStdObject, into result: inout [FCStdDocument.Instance]) {
        guard link.isVisible else {
            hiddenShapeCount += 1
            return
        }
        guard link.linkedFile.isEmpty else {
            warnings.append(
                "\(link.displayLabel) links to another file (\(link.linkedFile)) and was not drawn."
            )
            return
        }
        guard link.linkedSubName.isEmpty else {
            warnings.append(
                "\(link.displayLabel) links to a sub-element (\(link.linkedSubName)) and was not drawn."
            )
            return
        }
        guard let targetName = link.linkedObjectName, let target = byName[targetName] else {
            return
        }
        // ShowElement arrays materialize their entries as App::LinkElement
        // objects; those resolve here on their own, so the parent must not draw
        // a second copy.
        guard link.elementChildren.isEmpty else {
            return
        }
        if link.hasScale {
            warnings.append("\(link.displayLabel) is a scaled link; it is drawn unscaled.")
        }

        // The link's own frame: its App::Part ancestors, plus — for an element
        // of an array or link group — the claiming parent's own placement,
        // which FreeCAD composes ahead of every element.
        var prefix = groupTransform(of: link.name)
        if let parentName = elementParent[link.name], let parent = byName[parentName] {
            prefix = groupTransform(of: parentName) * parent.ownPlacement
        }
        let base = prefix * link.ownPlacement

        if link.elementCount > 0 {
            let placements = placementList(of: link)
            for index in 0..<link.elementCount {
                guard link.isElementVisible(index) else {
                    hiddenShapeCount += 1
                    continue
                }
                let element = index < placements.count ? placements[index] : .identity
                emit(
                    target: target,
                    transform: base * element,
                    keepTargetPlacement: link.linkTransform,
                    label: "\(link.displayLabel) [\(index)]",
                    into: &result,
                    depth: 0
                )
            }
        } else {
            emit(
                target: target,
                transform: base,
                keepTargetPlacement: link.linkTransform,
                label: link.displayLabel,
                into: &result,
                depth: 0
            )
        }
    }

    /// Lands one resolved link occurrence on `target`, following link chains.
    /// `keepTargetPlacement` mirrors FreeCAD's `LinkTransform`: the target's own
    /// placement either composes into the result or is overridden by the link.
    private mutating func emit(
        target: FCStdObject,
        transform: FCStdPlacement,
        keepTargetPlacement: Bool,
        label: String,
        into result: inout [FCStdDocument.Instance],
        depth: Int
    ) {
        guard depth < maxDepth else {
            return
        }

        if target.linkedObjectName != nil || !target.linkedFile.isEmpty {
            // A link to a link: the intermediate link's own placement counts
            // only when the upstream link carries transforms through.
            guard target.linkedFile.isEmpty else {
                warnings.append(
                    "\(label) links to another file (\(target.linkedFile)) and was not drawn."
                )
                return
            }
            guard let nextName = target.linkedObjectName, let next = byName[nextName] else {
                return
            }
            let carried = keepTargetPlacement ? transform * target.ownPlacement : transform
            emit(
                target: next,
                transform: carried,
                keepTargetPlacement: target.linkTransform,
                label: label,
                into: &result,
                depth: depth + 1
            )
            return
        }

        if target.shapeFile != nil {
            // The stored payload already contains the target's placement; keep
            // it or cancel it with its inverse, per LinkTransform.
            let placement = keepTargetPlacement
                ? transform
                : transform * target.placement.inverse
            if let instance = shapeInstance(target: target, label: label, placement: placement) {
                result.append(instance)
            }
            return
        }

        if !target.groupChildren.isEmpty {
            // A link to a whole App::Part: members are stored in the group's
            // local frame, so the group's own placement is what LinkTransform
            // keeps or discards.
            let groupFrame = keepTargetPlacement ? transform * target.placement : transform
            expandGroup(target, transform: groupFrame, label: label, into: &result, depth: depth)
        }
    }

    private mutating func expandGroup(
        _ group: FCStdObject,
        transform: FCStdPlacement,
        label: String,
        into result: inout [FCStdDocument.Instance],
        depth: Int
    ) {
        guard depth < maxDepth else {
            return
        }
        for childName in group.groupChildren {
            guard let child = byName[childName], child.isVisible else {
                continue
            }
            if child.shapeFile != nil, !ownedByContainer.contains(child.name) {
                // The child's stored shape already carries its (group-local)
                // placement, so the group frame is all that's left to apply.
                if let instance = shapeInstance(
                    target: child,
                    label: "\(label) / \(child.displayLabel)",
                    placement: transform
                ) {
                    result.append(instance)
                }
            } else if child.typeName == "App::Part" {
                expandGroup(
                    child,
                    transform: transform * child.placement,
                    label: label,
                    into: &result,
                    depth: depth + 1
                )
            }
        }
    }

    // MARK: Helpers

    /// The product of the ancestor `App::Part` placements enclosing `name`,
    /// outermost first — the transform FreeCAD's scenegraph applies on top of
    /// an object's stored geometry.
    private func groupTransform(of name: String) -> FCStdPlacement {
        var chain = [FCStdPlacement]()
        var current = partParent[name]
        var depth = 0
        while let parentName = current, depth < 64 {
            if let parent = byName[parentName] {
                chain.append(parent.placement)
            }
            current = partParent[parentName]
            depth += 1
        }
        return chain.reversed().reduce(.identity, *)
    }

    private func shapeInstance(
        target: FCStdObject,
        label: String,
        placement: FCStdPlacement
    ) -> FCStdDocument.Instance? {
        // FreeCAD stores a zero-length payload for an object whose shape is
        // empty — a sketch with no solid, say. There is nothing to draw.
        guard let shapeFile = target.shapeFile,
              let entry = archive.entry(named: shapeFile),
              entry.uncompressedSize > 0 else {
            return nil
        }
        return FCStdDocument.Instance(
            objectName: target.name,
            label: label,
            entryName: shapeFile,
            placement: placement.isIdentity ? nil : placement
        )
    }

    /// Decodes the link's `PlacementList` doc-file: little-endian `uint32`
    /// count, then seven values per placement — position x, y, z and quaternion
    /// x, y, z, w — as doubles or floats depending on the file's precision
    /// setting, told apart by the payload size.
    private func placementList(of link: FCStdObject) -> [FCStdPlacement] {
        guard let file = link.placementListFile,
              let data = (try? archive.contents(ofEntryNamed: file)) ?? nil,
              let count32: UInt32 = data.readLE(at: 0), count32 > 0 else {
            return []
        }
        let count = Int(count32)
        let body = data.count - 4
        let stride = body / count
        guard stride == 56 || stride == 28, body >= stride * count else {
            return []
        }

        func value(_ index: Int, _ component: Int) -> Double? {
            let offset = 4 + index * stride + component * (stride / 7)
            if stride == 56 {
                guard let bits: UInt64 = data.readLE(at: offset) else { return nil }
                return Double(bitPattern: bits)
            }
            guard let bits: UInt32 = data.readLE(at: offset) else { return nil }
            return Double(Float(bitPattern: bits))
        }

        var placements = [FCStdPlacement]()
        placements.reserveCapacity(count)
        for index in 0..<count {
            guard let px = value(index, 0), let py = value(index, 1), let pz = value(index, 2),
                  let qx = value(index, 3), let qy = value(index, 4), let qz = value(index, 5),
                  let qw = value(index, 6) else {
                return placements
            }
            placements.append(FCStdPlacement(
                rotation: SIMD4(qx, qy, qz, qw),
                position: SIMD3(px, py, pz)
            ))
        }
        return placements
    }
}

/// Per-object display colour, which lives in `GuiDocument.xml` rather than
/// `Document.xml` — it is view data, not model data, so the FreeCAD *core* does
/// not carry it either — BREP has no notion of appearance.
public enum FCStdAppearance {
    /// Display colours for a document's objects, keyed by internal object name.
    public struct Colors: Sendable {
        /// The whole-object shape colour.
        public var shape = [String: SIMD3<Float>]()
        /// Per-face colours (`DiffuseColor`), in the shape's face order — the
        /// order `TopExp::MapShapes(TopAbs_FACE)` yields, which is how FreeCAD
        /// itself maps them. Only stored when the list distinguishes faces;
        /// a single-entry list means the shape colour already tells the story.
        public var faces = [String: [SIMD3<Float>]]()
    }

    /// Reads both colour layers in one parse of `GuiDocument.xml`.
    public static func colors(in archive: ZipArchive) -> Colors {
        guard let xml = (try? archive.contents(ofEntryNamed: "GuiDocument.xml")) ?? nil else {
            return Colors()
        }
        let delegate = ColorDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()

        var colors = Colors(shape: delegate.colors)
        for (object, file) in delegate.diffuseFiles {
            guard let data = (try? archive.contents(ofEntryNamed: file)) ?? nil,
                  let list = decodeColorList(data), list.count > 1 else {
                continue
            }
            colors.faces[object] = list
        }
        return colors
    }

    /// FreeCAD packs colour as 0xRRGGBBAA. The alpha byte carries transparency
    /// conventions that changed across versions, so only RGB is used here.
    static func unpack(_ packed: UInt32) -> SIMD3<Float> {
        SIMD3(
            Float((packed >> 24) & 0xFF) / 255,
            Float((packed >> 16) & 0xFF) / 255,
            Float((packed >> 8) & 0xFF) / 255
        )
    }

    /// Decodes a `PropertyColorList` doc-file: little-endian `uint32` count,
    /// then one packed 0xRRGGBBAA `uint32` per colour.
    static func decodeColorList(_ data: Data) -> [SIMD3<Float>]? {
        guard let count32: UInt32 = data.readLE(at: 0) else {
            return nil
        }
        let count = Int(count32)
        guard count > 0, data.count >= 4 + count * 4 else {
            return nil
        }
        var colors = [SIMD3<Float>]()
        colors.reserveCapacity(count)
        for index in 0..<count {
            guard let packed: UInt32 = data.readLE(at: 4 + index * 4) else {
                return nil
            }
            colors.append(unpack(packed))
        }
        return colors
    }

    private final class ColorDelegate: NSObject, XMLParserDelegate {
        var colors = [String: SIMD3<Float>]()
        /// Object name → zip entry holding its DiffuseColor list.
        var diffuseFiles = [String: String]()
        private var currentObject: String?
        private var currentProperty: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "ViewProvider":
                currentObject = attributes["name"]
            case "Property":
                currentProperty = attributes["name"]
            case "PropertyColor":
                if currentProperty == "ShapeColor",
                   let object = currentObject,
                   let raw = attributes["value"],
                   let packed = UInt32(raw) {
                    colors[object] = FCStdAppearance.unpack(packed)
                }
            case "ColorList":
                if currentProperty == "DiffuseColor",
                   let object = currentObject,
                   let file = attributes["file"],
                   !file.isEmpty {
                    diffuseFiles[object] = file
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if elementName == "ViewProvider" {
                currentObject = nil
            } else if elementName == "Property" {
                currentProperty = nil
            }
        }
    }
}

// MARK: - Document.xml parsing

/// One object's fields as read from `Document.xml`.
private struct FCStdObject {
    var name: String
    var typeName: String = ""
    var label: String = ""
    var shapeFile: String?
    /// Objects this one contains, from its Group property.
    var groupChildren: [String] = []
    /// Materialized array elements, from an App::Link's ElementList.
    var elementChildren: [String] = []
    // FreeCAD writes Visibility for objects that have it; those that don't (plain
    // Part::Feature in older files) are treated as visible.
    var isVisible: Bool = true

    var placementValue: FCStdPlacement?
    var linkPlacementValue: FCStdPlacement?
    var linkedObjectName: String?
    /// Non-empty when the link points into another document (external XLink).
    var linkedFile: String = ""
    /// Non-empty when the link targets a sub-element rather than a whole object.
    var linkedSubName: String = ""
    var linkTransform: Bool = false
    var elementCount: Int = 0
    var placementListFile: String?
    /// `VisibilityList` as saved: a boost bitset string, *highest element
    /// first* — element `i` is the character at `count - 1 - i`.
    var visibilityBits: String = ""
    var hasScale: Bool = false

    var displayLabel: String {
        label.isEmpty ? name : label
    }

    var placement: FCStdPlacement {
        placementValue ?? .identity
    }

    /// A link's own placement — `LinkPlacement` when set, else `Placement`,
    /// matching `LinkBaseExtension::getTransform`.
    var ownPlacement: FCStdPlacement {
        linkPlacementValue ?? placementValue ?? .identity
    }

    func isElementVisible(_ index: Int) -> Bool {
        guard !visibilityBits.isEmpty else {
            return true
        }
        let characters = Array(visibilityBits)
        let position = characters.count - 1 - index
        guard characters.indices.contains(position) else {
            return true
        }
        return characters[position] != "0"
    }
}

/// SAX walk over `Document.xml`. Streaming rather than DOM because these files run
/// to megabytes, and because `XMLDocument` is macOS-only — `XMLParser` is the one
/// that also exists on iOS.
private enum FCStdManifestParser {
    static func parse(_ data: Data) -> [FCStdObject] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.objects.map { object in
            var object = object
            object.typeName = delegate.typesByName[object.name] ?? ""
            return object
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var objects = [FCStdObject]()
        /// Object name → type, from the `<Objects>` index — the one place the
        /// document states what each object *is* (`App::Link`, `App::Part`, …).
        var typesByName = [String: String]()

        // `<Object name=…>` appears both in the `<Objects>` index and in
        // `<ObjectData>`; only the latter carries properties, so gate on it.
        private var inObjectData = false
        private var current: FCStdObject?
        private var currentProperty: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "ObjectData":
                inObjectData = true

            case "Object":
                if inObjectData {
                    if let name = attributes["name"] {
                        current = FCStdObject(name: name)
                    }
                } else if let name = attributes["name"], let type = attributes["type"] {
                    typesByName[name] = type
                }

            case "Property":
                currentProperty = attributes["name"]

            case "Part":
                if currentProperty == "Shape", let file = attributes["file"] {
                    current?.shapeFile = file
                }

            case "Link":
                // Group and ElementList arrive as <Link value=…> children; Tip
                // and BaseFeature are Links too, and they point at members
                // rather than claiming them.
                if let value = attributes["value"], !value.isEmpty {
                    switch currentProperty {
                    case "Group":
                        current?.groupChildren.append(value)
                    case "ElementList":
                        current?.elementChildren.append(value)
                    case "LinkedObject":
                        // Ancient documents stored the target as a plain Link.
                        current?.linkedObjectName = value
                    default:
                        break
                    }
                }

            case "XLink":
                if currentProperty == "LinkedObject" {
                    current?.linkedObjectName = attributes["name"]
                    current?.linkedFile = attributes["file"] ?? ""
                    current?.linkedSubName = attributes["sub"] ?? ""
                }

            case "PropertyPlacement":
                guard let placement = Self.placement(from: attributes) else {
                    break
                }
                if currentProperty == "Placement" {
                    current?.placementValue = placement
                } else if currentProperty == "LinkPlacement" {
                    current?.linkPlacementValue = placement
                }

            case "PlacementList":
                if currentProperty == "PlacementList", let file = attributes["file"], !file.isEmpty {
                    current?.placementListFile = file
                }

            case "Integer":
                if currentProperty == "ElementCount", let value = attributes["value"] {
                    current?.elementCount = max(Int(value) ?? 0, 0)
                }

            case "Float":
                if currentProperty == "Scale", let value = attributes["value"],
                   let scale = Double(value), abs(scale - 1) > 1e-9 {
                    current?.hasScale = true
                }

            case "Bool":
                if let value = attributes["value"] {
                    switch currentProperty {
                    case "Visibility":
                        current?.isVisible = (value == "true")
                    case "LinkTransform":
                        current?.linkTransform = (value == "true")
                    default:
                        break
                    }
                }

            case "BoolList":
                if currentProperty == "VisibilityList", let value = attributes["value"] {
                    current?.visibilityBits = value
                }

            case "String":
                if currentProperty == "Label", let value = attributes["value"] {
                    current?.label = value
                }

            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "ObjectData":
                inObjectData = false
            case "Object" where inObjectData:
                if let current {
                    objects.append(current)
                }
                current = nil
            case "Property":
                currentProperty = nil
            default:
                break
            }
        }

        /// `Px/Py/Pz` + quaternion `Q0…Q3` (x, y, z, w); documents old enough to
        /// predate the quaternion attributes fall back to axis + angle (radians).
        private static func placement(from attributes: [String: String]) -> FCStdPlacement? {
            func number(_ key: String) -> Double? {
                attributes[key].flatMap(Double.init)
            }
            let position = SIMD3(
                number("Px") ?? 0,
                number("Py") ?? 0,
                number("Pz") ?? 0
            )
            if let q0 = number("Q0"), let q1 = number("Q1"),
               let q2 = number("Q2"), let q3 = number("Q3") {
                return FCStdPlacement(rotation: SIMD4(q0, q1, q2, q3), position: position)
            }
            if let angle = number("A"), let ox = number("Ox"), let oy = number("Oy"),
               let oz = number("Oz") {
                let axis = SIMD3(ox, oy, oz)
                let length = simd_length(axis)
                guard length > 1e-12 else {
                    return FCStdPlacement(rotation: SIMD4(0, 0, 0, 1), position: position)
                }
                let half = angle / 2
                let vector = axis / length * sin(half)
                return FCStdPlacement(
                    rotation: SIMD4(vector.x, vector.y, vector.z, cos(half)),
                    position: position
                )
            }
            return FCStdPlacement(rotation: SIMD4(0, 0, 0, 1), position: position)
        }
    }
}
