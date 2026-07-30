#if os(macOS)
import AppKit
@preconcurrency import QuickLookThumbnailing
import SceneKit
import StairsCore

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let fileURL = request.fileURL
        let maximumSize = request.maximumSize
        let scale = request.scale
        nonisolated(unsafe) let completion = handler

        Task { @MainActor in
            do {
                let imageURL = try await Self.thumbnailImageURL(
                    fileURL: fileURL,
                    maximumSize: maximumSize,
                    scale: scale
                )
                let reply = QLThumbnailReply(imageFileURL: imageURL)
                reply.extensionBadge = fileURL.pathExtension.uppercased()
                completion(reply, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    @MainActor
    private static func thumbnailImageURL(
        fileURL: URL,
        maximumSize: CGSize,
        scale: CGFloat
    ) async throws -> URL {
        let model = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return try StepMeshImporter.load(data: data, fileName: fileURL.lastPathComponent)
        }.value

        let image = render(model: model, maximumSize: maximumSize, scale: scale)
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StairsThumbnail-\(UUID().uuidString)")
            .appendingPathExtension("png")

        guard let data = pngData(for: image) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: imageURL, options: .atomic)
        return imageURL
    }

    @MainActor
    private static func render(model: StepModel, maximumSize: CGSize, scale: CGFloat) -> NSImage {
        let side = max(min(max(maximumSize.width, maximumSize.height), 768), 64)
        let pixelSide = max(Int((side * max(scale, 1)).rounded()), 64)
        let pointSide = CGFloat(pixelSide) / max(scale, 1)
        let frame = NSRect(x: 0, y: 0, width: pointSide, height: pointSide)
        let presentation = StepSceneFactory.presentation(
            for: model,
            options: StepSceneOptions(showsAxes: false, showsGrid: false),
            isDarkMode: false
        )

        let sceneView = SCNView(frame: frame)
        presentation.apply(
            to: sceneView,
            allowsCameraControl: false,
            autoenablesDefaultLighting: true
        )
        sceneView.layer?.contentsScale = max(scale, 1)

        let snapshot = sceneView.snapshot()
        snapshot.size = NSSize(width: pointSide, height: pointSide)
        return snapshot
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
