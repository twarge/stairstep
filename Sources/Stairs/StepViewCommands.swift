import StairsCore
import SwiftUI

struct StepViewMenuState: Equatable {
    var options: Binding<StepSceneOptions>
    var canUseStepColors: Bool
    var cameraProjection: Binding<StepCameraProjection>
    var cameraState: Binding<StepSceneCameraState?>
    var resetID: Binding<UUID>
    var applyPrimaryView: (StepPrimaryView) -> Void
    var section: Binding<StepSectionPlane>
    var canSection: Bool
    var canCopyModel: Bool
    var copyModel: () -> Void
    var canExportModel: Bool
    var exportModel: (StepExportFormat) -> Void
    var copyModelAs: (StepExportFormat) -> Void

    // The bindings all point at stable @State/@AppStorage storage, so the only
    // values that affect how the menu renders are the capability flags. Comparing
    // just those lets SwiftUI dedupe the published value instead of treating it as
    // changed on every body pass. Without this, each render re-invalidates the
    // document view and spins the main thread in an infinite layout loop on iOS.
    static func == (lhs: StepViewMenuState, rhs: StepViewMenuState) -> Bool {
        lhs.canUseStepColors == rhs.canUseStepColors
            && lhs.canSection == rhs.canSection
            && lhs.canCopyModel == rhs.canCopyModel
            && lhs.canExportModel == rhs.canExportModel
    }

    var usesPerspectiveProjection: Binding<Bool> {
        let projection = cameraProjection
        return Binding {
            projection.wrappedValue == .perspective
        } set: { usesPerspective in
            projection.wrappedValue = usesPerspective ? .perspective : .orthographic
        }
    }
}

private struct StepViewMenuStateKey: FocusedValueKey {
    typealias Value = StepViewMenuState
}

extension FocusedValues {
    var stepViewMenuState: StepViewMenuState? {
        get { self[StepViewMenuStateKey.self] }
        set { self[StepViewMenuStateKey.self] = newValue }
    }
}

struct StepViewCommands: Commands {
    @FocusedValue(\.stepViewMenuState) private var menuState
    #if os(macOS)
    @Environment(\.newDocument) private var newDocument
    #endif
    @AppStorage(StairsDistractionFree.storageKey) private var distractionFreeMode = StairsDistractionFree.defaultValue
    @AppStorage("useRealityKitRenderer") private var useRealityKitRenderer = false
    #if !os(macOS)
    // macOS keeps these in the Settings window, but SwiftUI's `Settings` scene is
    // macOS-only — so on the iPadOS menu bar these would otherwise be unreachable.
    @AppStorage("reverseHorizontalRotation") private var reverseHorizontalRotation = StairsRotationDefaults.reverseHorizontal
    @AppStorage("reverseVerticalRotation") private var reverseVerticalRotation = StairsRotationDefaults.reverseVertical
    #endif

    var body: some Commands {
        // Replaces the standard pasteboard group: this app has no text to cut or
        // paste into, so Copy means "copy the model" and Paste opens what's on the
        // clipboard as a new document.
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Model") {
                menuState?.copyModel()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(menuState?.canCopyModel != true)

            // Mesh formats only — see StepExportFormat on why STEP isn't offered.
            Menu("Copy As") {
                ForEach(StepExportFormat.allCases) { format in
                    Button(format.displayName) {
                        menuState?.copyModelAs(format)
                    }
                }
            }
            .disabled(menuState?.canExportModel != true)

            // macOS only: `newDocument` is unavailable on iOS. There, the empty
            // document's PasteButton covers this — and being system-mediated it
            // reads the clipboard without the paste confirmation a command needs.
            #if os(macOS)
            Button("New from Clipboard") {
                guard let pasted = StairsClipboard.pastedDocument() else { return }
                newDocument(pasted)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            #endif
        }

        CommandGroup(after: .saveItem) {
            Menu("Export As") {
                ForEach(StepExportFormat.allCases) { format in
                    Button("\(format.displayName)…") {
                        menuState?.exportModel(format)
                    }
                }
            }
            .disabled(menuState?.canExportModel != true)
        }

        CommandGroup(after: .sidebar) {
            if let menuState {
                Divider()

                Button("Home") {
                    menuState.cameraState.wrappedValue = nil
                    menuState.resetID.wrappedValue = UUID()
                }

                // The canvas key shortcuts (1–6, i/d/t) fire only with the
                // canvas focused, deliberately not shown here as equivalents:
                // bare-key menu equivalents would intercept typing in the
                // inspector's fields.
                Menu("Viewpoint") {
                    ForEach(StepPrimaryView.axisCases, id: \.self) { primary in
                        Button(primary.displayName) {
                            menuState.applyPrimaryView(primary)
                        }
                    }

                    Divider()

                    ForEach(StepPrimaryView.axonometricCases, id: \.self) { primary in
                        Button(primary.displayName) {
                            menuState.applyPrimaryView(primary)
                        }
                    }
                }

                Toggle("Perspective", isOn: menuState.usesPerspectiveProjection)

                // Also in Settings on macOS, but iPadOS has no Settings scene — and
                // it wants a shortcut on both platforms regardless.
                Toggle("Distraction-Free Mode", isOn: $distractionFreeMode)
                    .keyboardShortcut("d", modifiers: [.command, .control])

                Divider()

                Toggle("Axes", isOn: menuState.options.showsAxes)
                Toggle("Grid", isOn: menuState.options.showsGrid)
                Toggle("Floor", isOn: menuState.options.showsFloor)
                Toggle("Wireframe", isOn: menuState.options.showsWireframe)
                Toggle("STEP Colors", isOn: menuState.options.usesOriginalColors)
                    .disabled(!menuState.canUseStepColors)
                // The engine-port scaffold: model display, orbit, and zoom only —
                // sections, measurement overlays, and the rest still render in the
                // SceneKit canvas until they port.
                Toggle("RealityKit Renderer (Experimental)", isOn: $useRealityKitRenderer)

                Divider()

                Toggle("Cross Section", isOn: menuState.section.isEnabled)
                    .disabled(!menuState.canSection)
                Toggle("Flip Section Side", isOn: menuState.section.isFlipped)
                    .disabled(!menuState.canSection || !menuState.section.wrappedValue.isEnabled)
                Toggle("Solid Section Cap", isOn: menuState.section.showsCap)
                    .disabled(!menuState.canSection || !menuState.section.wrappedValue.isEnabled)

                #if !os(macOS)
                Divider()

                Toggle("Reverse Horizontal Rotation", isOn: $reverseHorizontalRotation)
                Toggle("Reverse Vertical Rotation", isOn: $reverseVerticalRotation)
                #endif
            }
        }
    }
}
