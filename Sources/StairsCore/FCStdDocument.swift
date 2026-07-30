import Foundation

/// Reads the parts of a FreeCAD `.FCStd` document this app needs to draw it.
///
/// An `.FCStd` is a zip holding `Document.xml` (the object graph and every
/// property) plus one OpenCascade BREP file per shape-bearing object, named
/// `PartShape*.brp`. Rather than importing every BREP — a PartDesign body stores
/// each intermediate feature alongside its final solid, so that would draw the
/// same part several times over — this walks `Document.xml` and keeps only the
/// objects FreeCAD itself would show.
///
/// This is a reader, not a document model: no parametric history, no recompute.
/// It is enough to render what the file already contains.
public struct FCStdDocument: Sendable {
    public struct Shape: Sendable {
        /// The object's internal name, e.g. `Body012`.
        public let objectName: String
        /// The user-facing label when the file has one, else the object name.
        public let label: String
        /// Zip entry holding this object's BREP payload.
        public let entryName: String
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

    private let archive: ZipArchive

    /// Visible, shape-bearing objects in document order.
    public let shapes: [Shape]
    /// Objects carrying geometry that are hidden in the saved document. Kept for
    /// reporting — a document that is entirely hidden should say so rather than
    /// look empty.
    public let hiddenShapeCount: Int

    public init(data: Data) throws {
        let archive = try ZipArchive(data: data)
        guard let documentXML = try archive.contents(ofEntryNamed: "Document.xml") else {
            throw Error.missingDocumentXML
        }

        let objects = FCStdManifestParser.parse(documentXML)
        let withGeometry = objects.filter { $0.shapeFile != nil }
        let visible = withGeometry.filter(\.isVisible)

        // A document whose objects are all hidden still has geometry worth
        // showing; falling back beats presenting an empty viewport.
        let selected = visible.isEmpty ? withGeometry : visible

        self.archive = archive
        self.hiddenShapeCount = withGeometry.count - visible.count
        self.shapes = selected.compactMap { object in
            // FreeCAD stores a zero-length payload for an object whose shape is
            // empty — a sketch with no solid, say. There is nothing to draw, so
            // drop it here and keep `shapes` aligned with `brepPayloads()`.
            guard let shapeFile = object.shapeFile,
                  let entry = archive.entry(named: shapeFile),
                  entry.uncompressedSize > 0 else {
                return nil
            }
            return Shape(
                objectName: object.name,
                label: object.label.isEmpty ? object.name : object.label,
                entryName: shapeFile
            )
        }

        if shapes.isEmpty {
            throw Error.noVisibleShapes
        }
    }

    /// Inflates each selected shape's BREP payload, in document order. Entries
    /// that fail to inflate are skipped rather than failing the whole document.
    public func brepPayloads() -> [Data] {
        shapes.compactMap { shape in
            guard let entry = archive.entry(named: shape.entryName) else {
                return nil
            }
            return try? archive.contents(of: entry)
        }
    }
}

// MARK: - Document.xml parsing

/// One object's fields as read from `Document.xml`.
private struct FCStdObject {
    var name: String
    var label: String = ""
    var shapeFile: String?
    // FreeCAD writes Visibility for objects that have it; those that don't (plain
    // Part::Feature in older files) are treated as visible.
    var isVisible: Bool = true
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
        return delegate.objects
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var objects = [FCStdObject]()

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

            case "Object" where inObjectData:
                if let name = attributes["name"] {
                    current = FCStdObject(name: name)
                }

            case "Property":
                currentProperty = attributes["name"]

            case "Part":
                if currentProperty == "Shape", let file = attributes["file"] {
                    current?.shapeFile = file
                }

            case "Bool":
                if currentProperty == "Visibility", let value = attributes["value"] {
                    current?.isVisible = (value == "true")
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
    }
}
