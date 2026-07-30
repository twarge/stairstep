#if os(macOS)
import AppKit
@preconcurrency import QuickLookUI
import SceneKit
import StairsCore

final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private let sceneView = SCNView(frame: .zero)
    private let messageLabel = NSTextField(labelWithString: "Loading model...")

    override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 620))
        rootView.wantsLayer = true
        view = rootView
        preferredContentSize = rootView.frame.size

        configureSceneView()
        configureMessageLabel()
        updateColors()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        showMessage("Loading model...")

        Task { @MainActor in
            do {
                let model = try await Self.loadModel(from: url)
                display(model)
                handler(nil)
            } catch {
                showMessage(error.localizedDescription)
                handler(error)
            }
        }
    }

    private static func loadModel(from url: URL) async throws -> StepModel {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try StepMeshImporter.load(data: data, fileName: url.lastPathComponent)
        }.value
    }

    private func configureSceneView() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureMessageLabel() {
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 4

        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28)
        ])
    }

    private func display(_ model: StepModel) {
        let presentation = StepSceneFactory.presentation(
            for: model,
            options: StepSceneOptions(),
            isDarkMode: isDarkMode
        )
        presentation.apply(
            to: sceneView,
            allowsCameraControl: true,
            autoenablesDefaultLighting: true
        )

        sceneView.isHidden = false
        messageLabel.isHidden = true
    }

    private func showMessage(_ message: String) {
        sceneView.isHidden = true
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    private func updateColors() {
        let color = backgroundColor
        view.layer?.backgroundColor = color.cgColor
        sceneView.backgroundColor = color
        sceneView.scene?.background.contents = color
        messageLabel.textColor = isDarkMode ? .white : .black
    }

    private var backgroundColor: NSColor {
        NSColor.stairsBackground(isDarkMode: isDarkMode)
    }

    private var isDarkMode: Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
#endif
