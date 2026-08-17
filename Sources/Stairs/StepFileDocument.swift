import Foundation
import StairsCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import CoreTransferable
import UIKit
#endif

extension UTType {
    // Non-isolated so the nonisolated `FileDocument` content-type requirements
    // (and any actor) can reference them under main-actor-by-default isolation.
    nonisolated static let stepModel = UTType(exportedAs: "com.twarge.stairs.step", conformingTo: .text)
    nonisolated static let igesModel = UTType(exportedAs: "com.twarge.stairs.iges", conformingTo: .text)
    nonisolated static let brepModel = UTType(exportedAs: "com.twarge.stairs.brep", conformingTo: .data)
    nonisolated static let stlModel = UTType(exportedAs: "com.twarge.stairs.stl", conformingTo: .data)
    nonisolated static let plyModel = UTType(exportedAs: "com.twarge.stairs.ply", conformingTo: .data)
    nonisolated static let objModel = UTType(exportedAs: "com.twarge.stairs.obj", conformingTo: .text)
    nonisolated static let glbModel = UTType(exportedAs: "com.twarge.stairs.glb", conformingTo: .data)
    // A FreeCAD document is a zip container, so it conforms to .zip rather than .data.
    nonisolated static let freeCADModel = UTType(exportedAs: "com.twarge.stairs.fcstd", conformingTo: .zip)
}

nonisolated struct StepFileDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] {
        [.stepModel, .igesModel, .brepModel, .stlModel, .plyModel, .objModel, .glbModel, .freeCADModel]
    }

    static var writableContentTypes: [UTType] { [.stepModel] }

    var id: UUID
    var data: Data
    var fileName: String

    init(data: Data = Data(), fileName: String = "Untitled.step") {
        id = UUID()
        self.data = data
        self.fileName = fileName
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.init(
            data: contents,
            fileName: configuration.file.preferredFilename
                ?? configuration.file.filename
                ?? "STEP model.step"
        )
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = fileName
        return wrapper
    }
}

/// Carries exported bytes to `fileExporter`. Write-only: exports never come back
/// in through this type, they come in as `StepFileDocument`.
nonisolated struct ExportedModelDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] {
        StepExportFormat.allCases.compactMap { UTType($0.contentTypeIdentifier) }
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#if os(iOS)
/// One shareable rendition of the open model — the original document bytes or a
/// mesh conversion — typed for `ShareLink`. Encoding is deferred: constructing
/// this is a value copy, and the bytes are only produced when a share target
/// actually asks.
nonisolated struct SharedModelFile: Transferable {
    enum Content {
        /// The document's own bytes, shared verbatim under its own format.
        case original(Data)
        /// A mesh conversion, encoded on demand.
        case export(mesh: StepTriangleMesh, format: StepExportFormat, modelName: String)
    }

    var filename: String
    var content: Content

    /// The type this file transfers as, and the key the representations below
    /// are selected by — so a `.glb` original is never announced as STEP.
    var contentType: UTType {
        switch content {
        case .original:
            return StairsClipboard.contentType(forFileNamed: filename)
        case .export(_, let format, _):
            return UTType(format.contentTypeIdentifier) ?? .data
        }
    }

    func data() throws -> Data {
        switch content {
        case .original(let data):
            return data
        case .export(let mesh, let format, let modelName):
            return try StepMeshExporter.data(for: mesh, format: format, modelName: modelName)
        }
    }

    /// One representation per model type this app declares, each offered only
    /// for the files that carry it — every readable type, because an original
    /// is shared under its own format, whatever was opened.
    ///
    /// Built through the helper below with every closure's types spelled out,
    /// which keeps the result builder tractable for the type checker.
    static var transferRepresentation: some TransferRepresentation {
        fileRepresentation(.stepModel)
        fileRepresentation(.igesModel)
        fileRepresentation(.brepModel)
        fileRepresentation(.stlModel)
        fileRepresentation(.plyModel)
        fileRepresentation(.objModel)
        fileRepresentation(.glbModel)
        fileRepresentation(.freeCADModel)
    }

    private static func fileRepresentation(
        _ type: UTType
    ) -> some TransferRepresentation<SharedModelFile> {
        let representation = FileRepresentation<SharedModelFile>(exportedContentType: type) {
            (file: SharedModelFile) async throws -> SentTransferredFile in
            SentTransferredFile(try file.writeTemporary(), allowAccessingOriginalFile: false)
        }
        return representation.exportingCondition { (file: SharedModelFile) -> Bool in
            file.contentType == type
        }
    }

    /// File transfers hand over a URL, so the bytes go through a uniquely-named
    /// temporary directory — which is also what lets the receiver see the real
    /// filename.
    private func writeTemporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data().write(to: url)
        return url
    }
}
#endif

/// Builds a document out of whatever was pasted, so an empty document can be
/// filled from the clipboard instead of only from a file on disk.
nonisolated enum StairsClipboard {
    /// What the paste button will accept: the model types this app reads, a
    /// reference to a copied file, and plain text — STEP and IGES are text formats,
    /// so a model is often carried as text rather than as a typed payload.
    static var supportedContentTypes: [UTType] {
        StepFileDocument.readableContentTypes + [.fileURL, .plainText]
    }

    /// The first pasted item that resolves to a model, or `nil` if none does.
    static func document(from providers: [NSItemProvider]) async -> StepFileDocument? {
        for provider in providers {
            // 1. One of our own model types, pasted verbatim.
            for type in StepFileDocument.readableContentTypes
            where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = await data(from: provider, type: type), !data.isEmpty {
                    let ext = type.preferredFilenameExtension ?? "step"
                    return StepFileDocument(data: data, fileName: "Pasted Model.\(ext)")
                }
            }

            // 2. A copied file — read it in place.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let reference = await data(from: provider, type: .fileURL),
               let url = URL(dataRepresentation: reference, relativeTo: nil),
               let contents = try? Data(contentsOf: url), !contents.isEmpty {
                return StepFileDocument(data: contents, fileName: url.lastPathComponent)
            }

            // 3. Plain text, but only when it actually looks like a STEP file. Any
            //    text would otherwise be accepted and fail later in the importer
            //    with a message that says nothing about the real problem.
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let data = await data(from: provider, type: .plainText),
               let text = String(data: data, encoding: .utf8),
               text.contains(stepHeaderSignature) {
                return StepFileDocument(data: Data(text.utf8), fileName: "Pasted Model.step")
            }
        }
        return nil
    }

    /// Every STEP file opens with this ISO 10303-21 exchange-structure marker.
    private static let stepHeaderSignature = "ISO-10303-21"

    /// The declared type matching a file's extension, so a copied model keeps its
    /// own format rather than being announced as STEP whatever it is.
    static func contentType(forFileNamed name: String) -> UTType {
        let ext = (name as NSString).pathExtension.lowercased()
        for type in StepFileDocument.readableContentTypes
        where type.tags[.filenameExtension]?.contains(ext) == true {
            return type
        }
        return .stepModel
    }

    /// Puts a model on the clipboard under its own type, and — for the text-based
    /// formats — as plain text too, so it can be pasted into an editor as well as
    /// back into this app.
    static func copy(_ document: StepFileDocument) {
        let type = contentType(forFileNamed: document.fileName)
        copy(document.data, as: type, includingText: type.conforms(to: .text))
    }

    /// Puts arbitrary model bytes on the clipboard under `type`, optionally also as
    /// plain text for the human-readable formats.
    static func copy(_ data: Data, as type: UTType, includingText: Bool) {
        let document = StepFileDocument(data: data)
        let text = includingText ? String(data: document.data, encoding: .utf8) : nil

        #if os(macOS)
        let item = NSPasteboardItem()
        item.setData(document.data, forType: NSPasteboard.PasteboardType(type.identifier))
        if let text {
            item.setString(text, forType: .string)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        #else
        var item: [String: Any] = [type.identifier: document.data]
        if let text {
            item[UTType.plainText.identifier] = text
        }
        UIPasteboard.general.items = [item]
        #endif
    }

    /// Reads the clipboard directly, for menu commands. `PasteButton` is preferred
    /// in the UI because the system mediates it; a command has no such affordance,
    /// so on iOS this is what triggers the standard paste confirmation.
    static func pastedDocument() -> StepFileDocument? {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        for type in StepFileDocument.readableContentTypes {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
                let ext = type.preferredFilenameExtension ?? "step"
                return StepFileDocument(data: data, fileName: "Pasted Model.\(ext)")
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                if let contents = try? Data(contentsOf: url), !contents.isEmpty {
                    return StepFileDocument(data: contents, fileName: url.lastPathComponent)
                }
            }
        }
        if let text = pasteboard.string(forType: .string), text.contains(stepHeaderSignature) {
            return StepFileDocument(data: Data(text.utf8), fileName: "Pasted Model.step")
        }
        #else
        let pasteboard = UIPasteboard.general
        for type in StepFileDocument.readableContentTypes {
            if let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty {
                let ext = type.preferredFilenameExtension ?? "step"
                return StepFileDocument(data: data, fileName: "Pasted Model.\(ext)")
            }
        }
        if pasteboard.hasURLs, let url = pasteboard.url,
           let contents = try? Data(contentsOf: url), !contents.isEmpty {
            return StepFileDocument(data: contents, fileName: url.lastPathComponent)
        }
        if pasteboard.hasStrings, let text = pasteboard.string, text.contains(stepHeaderSignature) {
            return StepFileDocument(data: Data(text.utf8), fileName: "Pasted Model.step")
        }
        #endif
        return nil
    }

    /// Whether the clipboard looks like it holds a model. Checked without reading
    /// the contents, so it doesn't trip iOS's paste confirmation just to decide
    /// whether a menu item should be enabled.
    static var hasModel: Bool {
        #if os(macOS)
        let available = NSPasteboard.general.types ?? []
        let identifiers = Set(available.map(\.rawValue))
        if StepFileDocument.readableContentTypes.contains(where: { identifiers.contains($0.identifier) }) {
            return true
        }
        return identifiers.contains(UTType.fileURL.identifier) || identifiers.contains(UTType.utf8PlainText.identifier)
        #else
        let pasteboard = UIPasteboard.general
        if pasteboard.contains(pasteboardTypes: StepFileDocument.readableContentTypes.map(\.identifier)) {
            return true
        }
        return pasteboard.hasURLs || pasteboard.hasStrings
        #endif
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
