import Foundation
import StairsCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum StairsTheme: String, CaseIterable, Identifiable {
    static let storageKey = "theme"

    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func resolvedColorScheme(systemColorScheme: ColorScheme) -> ColorScheme {
        preferredColorScheme ?? systemColorScheme
    }

    static var stored: StairsTheme {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return .system
        }
        return StairsTheme(rawValue: rawValue) ?? .system
    }

    static func theme(from notification: Notification) -> StairsTheme? {
        notification.object as? StairsTheme
    }
}

extension Notification.Name {
    static let stairsThemeDidChange = Notification.Name("StairsThemeDidChange")
}

#if STAIRS_SWIFTPM_EXECUTABLE
@main
struct StairsPackageEntryPoint {
    static func main() {
        let message = """
        Stairs is a macOS app bundle, not a Swift Package command-line app.

        Open Stairs.xcodeproj in Xcode and run the "Stairs" scheme so the app has its Info.plist, bundle identifier, resources, and Quick Look extensions.
        """
        FileHandle.standardError.write(Data(message.utf8))
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
#else
@main
struct StairsApp: App {
    @AppStorage(StairsTheme.storageKey) private var theme = StairsTheme.system

    var body: some Scene {
        DocumentGroup(newDocument: StairsDemoModel.defaultDocument()) { configuration in
            StepDocumentView(configuration: configuration, document: configuration.$document)
                .preferredColorScheme(theme.preferredColorScheme)
                #if os(macOS)
                .syncsStairsAppearance(theme)
                #endif
        }
        .commands {
            #if os(macOS)
            StairsDemoCommands()
            #else
            StairsNewWindowCommands()
            #endif
            #if os(macOS)
            CommandGroup(replacing: .appInfo) {
                Button("About Stairstep") {
                    Task { @MainActor in
                        StairsAboutPanel.show()
                    }
                }
            }
            #endif
            StepViewCommands()
        }

        #if os(macOS)
        Settings {
            StairsPreferencesView()
                .preferredColorScheme(theme.preferredColorScheme)
                .syncsStairsAppearance(theme)
        }
        #endif

        #if os(iOS)
        if #available(iOS 18.0, *) {
            DocumentGroupLaunchScene("Stairstep") {
                StairsDemoLaunchButton()
            }
        }
        #endif
    }
}
#endif

/// Anchors resource lookup to the bundle that contains this code, whatever the
/// hosting process's main bundle happens to be.
nonisolated private final class StairsBundleToken {}

nonisolated enum StairsDemoModel {
    static let resourceName = "Stair Demo"
    static let filenameExtension = "step"

    static var url: URL? {
        // Look in the bundle holding this code before `Bundle.main`. The document
        // launch UI can run in a host process whose main bundle is not this app.
        for bundle in [Bundle(for: StairsBundleToken.self), Bundle.main] {
            if let bundledURL = bundle.url(forResource: resourceName, withExtension: filenameExtension) {
                return bundledURL
            }
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("App")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).\(filenameExtension)")
        return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
    }

    static func loadedData() throws -> Data {
        guard let url else {
            NSLog("Stairstep: bundled demo model '%@.%@' not found in any bundle", resourceName, filenameExtension)
            throw StairsDemoModelError.missingBundledModel
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Never hand back empty contents: they would be written out as a 0-byte
        // file that looks like a successfully created model.
        guard !data.isEmpty else {
            NSLog("Stairstep: bundled demo model at %@ is empty", url.path)
            throw StairsDemoModelError.missingBundledModel
        }
        return data
    }

    static func document() throws -> StepFileDocument {
        StepFileDocument(data: try loadedData(), fileName: "\(resourceName).\(filenameExtension)")
    }

    /// Supplies the value used by DocumentGroup when iOS creates a document.
    /// The plain NewDocumentButton reliably serializes this value on hardware,
    /// unlike its template overloads. macOS keeps its normal empty default.
    static func defaultDocument() -> StepFileDocument {
        #if os(iOS)
        do {
            let document = try document()
            NSLog("Stairstep: prepared %d-byte demo document", document.data.count)
            return document
        } catch {
            NSLog("Stairstep: could not prepare demo document — %@", error.localizedDescription)
            return StepFileDocument()
        }
        #else
        return StepFileDocument()
        #endif
    }

}

nonisolated enum StairsDemoModelError: LocalizedError {
    case missingBundledModel

    var errorDescription: String? {
        switch self {
        case .missingBundledModel:
            "The bundled demo model could not be found."
        }
    }
}

#if os(iOS)
/// Replaces the standard "New" item, which for a viewer would only ever make an
/// empty document, with a command that opens another window on the same app.
///
/// `DocumentGroup` exposes no scene id, so SwiftUI's `openWindow` can't reach it;
/// asking UIKit to activate a fresh scene session is the supported route. The app
/// already declares `UIApplicationSupportsMultipleScenes`, so iPadOS honours it.
private struct StairsNewWindowCommands: Commands {
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                UIApplication.shared.activateSceneSession(
                    for: UISceneSessionActivationRequest()
                ) { error in
                    NSLog("Stairstep: could not open a new window — %@", error.localizedDescription)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            // iPhone runs a single scene; the command would silently do nothing.
            .disabled(!supportsMultipleWindows)
        }
    }
}

/// iOS counterpart of the macOS Settings window: SwiftUI's `Settings` scene is
/// macOS-only, so the same preferences open as a sheet from the toolbar gear.
struct StairsIOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StairsTheme.storageKey) private var theme = StairsTheme.system
    @AppStorage("showsFloor") private var showsFloor = false
    @AppStorage("usesColoredAccentLights") private var usesColoredAccentLights = true
    @AppStorage(StairsSectionColor.storageKey) private var sectionColorHex = StairsSectionColor.defaultHex
    @AppStorage("reverseHorizontalRotation") private var reverseHorizontalRotation = StairsRotationDefaults.reverseHorizontal
    @AppStorage("reverseVerticalRotation") private var reverseVerticalRotation = StairsRotationDefaults.reverseVertical
    @AppStorage(StairsDistractionFree.storageKey) private var distractionFreeMode = StairsDistractionFree.defaultValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        ForEach(StairsTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    Toggle("Distraction-Free Mode", isOn: $distractionFreeMode)
                    Text("Hides the toolbar. Tap the top of the screen to bring it back for a moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Lighting") {
                    Toggle("Floor", isOn: $showsFloor)
                    Toggle("Blue and Red Accent Lights", isOn: $usesColoredAccentLights)
                }

                Section("Cross Section") {
                    ColorPicker("Cut Face Fill", selection: sectionColorBinding, supportsOpacity: false)
                }

                Section("Navigation") {
                    Toggle("Reverse Horizontal Rotation", isOn: $reverseHorizontalRotation)
                    Toggle("Reverse Vertical Rotation", isOn: $reverseVerticalRotation)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var sectionColorBinding: Binding<Color> {
        Binding {
            Color(PlatformColor.stairsColor(hexString: sectionColorHex) ?? StairsSectionColor.fallback)
        } set: { newValue in
            sectionColorHex = PlatformColor(newValue).stairsHexString
        }
    }
}

@available(iOS 18.0, *)
private struct StairsDemoLaunchButton: View {
    var body: some View {
        // The template overload currently creates an empty file on hardware.
        // The plain button asks DocumentGroup to serialize its default value,
        // which StairsDemoModel.defaultDocument() seeds with the demo bytes.
        NewDocumentButton("Open Demo Document")
    }
}
#endif

#if os(macOS)
private extension StairsTheme {
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

private extension View {
    func syncsStairsAppearance(_ theme: StairsTheme) -> some View {
        self
            .task {
                StairsAppearanceSynchronizer.apply(StairsTheme.stored)
            }
            .onChange(of: theme) { _, newTheme in
                StairsAppearanceSynchronizer.apply(newTheme)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stairsThemeDidChange)) { notification in
                StairsAppearanceSynchronizer.apply(StairsTheme.theme(from: notification) ?? StairsTheme.stored)
            }
    }
}

private enum StairsAppearanceSynchronizer {
    private static var appliedTheme: StairsTheme?

    static func apply(_ theme: StairsTheme) {
        guard appliedTheme != theme else {
            refreshWindows(using: theme.appKitAppearance)
            return
        }

        appliedTheme = theme
        let appearance = theme.appKitAppearance
        NSApplication.shared.appearance = appearance
        refreshWindows(using: appearance)
    }

    private static func refreshWindows(using appearance: NSAppearance?) {
        Task { @MainActor in
            await Task.yield()
            markWindowsForAppearanceRefresh(using: appearance)
        }
    }

    private static func markWindowsForAppearanceRefresh(using appearance: NSAppearance?) {
        for window in NSApplication.shared.windows {
            window.appearance = appearance
            if let contentView = window.contentView {
                refreshViewTree(contentView, using: appearance)
            }
            window.invalidateShadow()
        }
    }

    private static func refreshViewTree(_ view: NSView, using appearance: NSAppearance?) {
        view.appearance = appearance
        view.needsLayout = true
        view.needsDisplay = true
        for subview in view.subviews {
            refreshViewTree(subview, using: appearance)
        }
    }
}

private struct StairsPreferencesView: View {
    @AppStorage(StairsTheme.storageKey) private var theme = StairsTheme.system
    @AppStorage("showsFloor") private var showsFloor = false
    @AppStorage("usesColoredAccentLights") private var usesColoredAccentLights = true
    @AppStorage(StairsSectionColor.storageKey) private var sectionColorHex = StairsSectionColor.defaultHex
    @AppStorage("reverseHorizontalRotation") private var reverseHorizontalRotation = StairsRotationDefaults.reverseHorizontal
    @AppStorage("reverseVerticalRotation") private var reverseVerticalRotation = StairsRotationDefaults.reverseVertical
    @AppStorage(StairsDistractionFree.storageKey) private var distractionFreeMode = StairsDistractionFree.defaultValue

    private var themeBinding: Binding<StairsTheme> {
        Binding {
            theme
        } set: { newTheme in
            theme = newTheme
            StairsAppearanceSynchronizer.apply(newTheme)
            NotificationCenter.default.post(name: .stairsThemeDidChange, object: newTheme)
        }
    }

    private var sectionColorBinding: Binding<Color> {
        Binding {
            Color(nsColor: PlatformColor.stairsColor(hexString: sectionColorHex) ?? StairsSectionColor.fallback)
        } set: { newValue in
            sectionColorHex = NSColor(newValue).stairsHexString
        }
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: themeBinding) {
                    ForEach(StairsTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Lighting") {
                Toggle("Floor", isOn: $showsFloor)
                Toggle("Blue and red accent lights", isOn: $usesColoredAccentLights)
            }

            Section("Cross Section") {
                ColorPicker("Cut face fill", selection: sectionColorBinding, supportsOpacity: false)
            }

            Section("Appearance") {
                Toggle("Distraction-Free Mode", isOn: $distractionFreeMode)
                Text("Hides the toolbar until you move the pointer to the top of the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Navigation") {
                Toggle("Reverse horizontal rotation", isOn: $reverseHorizontalRotation)
                Toggle("Reverse vertical rotation", isOn: $reverseVerticalRotation)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 360)
    }
}

private struct StairsDemoCommands: Commands {
    @Environment(\.openDocument) private var openDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Demo Model") {
                openDemoModel()
            }
        }
    }

    private func openDemoModel() {
        Task { @MainActor in
            guard let url = StairsDemoModel.url else {
                StairsDemoAlert.show(message: "The bundled demo model could not be found.")
                return
            }

            do {
                try await openDocument(at: url)
            } catch {
                StairsDemoAlert.show(message: error.localizedDescription)
            }
        }
    }
}

private enum StairsDemoAlert {
    static func show(message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to Open Demo Model"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum StairsAboutPanel {
    static func show() {
        let credits = """
        Stairstep uses Open CASCADE Technology (OCCT) 8.0.0 for 3D model import and tessellation.

        Open CASCADE Technology is copyright OPEN CASCADE S.A.S. OCCT is licensed under the GNU Lesser General Public License version 2.1 with the Open CASCADE exception.

        RapidJSON is used by OCCT's glTF importer and is licensed under the MIT License.

        The LGPL 2.1 text, Open CASCADE exception, and RapidJSON MIT license are included with Stairstep under Resources/ThirdPartyLicenses, in the generated static install or vendored source, and in the source repository through the Vendor submodules.
        """

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributedCredits = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: attributedCredits
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif
