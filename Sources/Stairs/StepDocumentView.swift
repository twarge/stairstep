import SceneKit
import StairsCore
import SwiftUI
import UniformTypeIdentifiers

/// Defaults for the orbit-direction preferences. Every `@AppStorage` declaration
/// of these keys must use the same default, or the value read depends on which
/// view happens to read it — so they live here rather than being repeated.
///
/// Vertical differs by platform: dragging a finger up the screen should tilt the
/// model as though pushing its top away, which is the opposite of the pointer
/// convention on macOS.
enum StairsRotationDefaults {
    static let reverseHorizontal = false
    #if os(macOS)
    static let reverseVertical = false
    #else
    static let reverseVertical = true
    #endif
}

/// Persisted colour used for the cross-section cap hatching and the translucent
/// cutting plane, shared by the document view and the Preferences window.
enum StairsSectionColor {
    static let storageKey = "sectionColorHex"
    /// A light CAD fill: the hatch lines are drawn black over this color, so it
    /// reads as the cut face's background rather than the line color. Matches the
    /// cross-section figure on the website.
    static let defaultHex = "#E2E8C1"
    static var fallback: PlatformColor { PlatformColor.stairsColor(hexString: defaultHex) ?? .systemBlue }
}

struct StepDocumentView: View {
    let configuration: FileDocumentConfiguration<StepFileDocument>
    @Binding var document: StepFileDocument

    @State private var loader = StepSceneLoader()
    @State private var cameraState: StepSceneCameraState?
    @State private var resetID = UUID()
    @State private var primaryViewRequest: StepPrimaryViewRequest?
    @State private var section = StepSectionPlane()
    @State private var isPickingSectionPoint = false
    // Tracks which model `section` was last initialized for, so a freshly loaded
    // model gets a sensible default plane position without clobbering the user's
    // adjustments while the same model stays open.
    @State private var sectionModelID: UUID?
    @State private var measurement = StepMeasurement()
    // Precomputed snap geometry for the measurement tool, built off the main actor
    // when a model loads.
    @State private var snapModel: StepSnapModel?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    // On compact width (iPhone) the inspector and the model view are separate
    // stacked screens inside one NavigationSplitView. The split view provides a
    // single back control — model view → inspector → document browser — as long
    // as the detail carries no title on compact (the document name titles the
    // inspector instead; a titled detail spawns a second navigation bar). It
    // starts on the detail, so iPhone opens on the model, not the inspector.
    @State private var preferredCompactColumn = NavigationSplitViewColumn.detail
    // Per-document-scene restoration of the camera. SceneStorage is persisted by
    // the system and handed back when a document scene is restored on relaunch,
    // so the view returns to exactly where it was left. Stored as JSON because
    // SceneStorage only holds property-list primitives.
    @SceneStorage("cameraState") private var cameraStateStore = ""
    // Side-by-side columns open on the model alone; the system sidebar toggle
    // brings in the inspector, and the last choice is kept.
    @AppStorage("sidebarVisibility") private var sidebarVisibility = "detailOnly"
    @AppStorage("showsAxes") private var showsAxes = false
    @AppStorage("showsGrid") private var showsGrid = true
    @AppStorage("showsFloor") private var showsFloor = false
    @AppStorage("showsWireframe") private var showsWireframe = false
    @AppStorage("usesOriginalColors") private var usesOriginalColors = true
    @AppStorage("usesColoredAccentLights") private var usesColoredAccentLights = true
    @AppStorage("cameraProjection") private var cameraProjection = StepCameraProjection.perspective
    @AppStorage("reverseHorizontalRotation") private var reverseHorizontalRotation = StairsRotationDefaults.reverseHorizontal
    @AppStorage("reverseVerticalRotation") private var reverseVerticalRotation = StairsRotationDefaults.reverseVertical
    @AppStorage(StairsTheme.storageKey) private var theme = StairsTheme.system
    @AppStorage(StairsSectionColor.storageKey) private var sectionColorHex = StairsSectionColor.defaultHex
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var observedTheme = StairsTheme.stored
    // Set when loading the demo or a pasted model fails, so the button reports the
    // reason instead of appearing to do nothing.
    @State private var modelErrorMessage: String?
    // Export runs through `fileExporter`, which needs the payload staged first.
    @State private var exportDocument: ExportedModelDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "model"
    @AppStorage(StairsDistractionFree.storageKey) private var distractionFreeMode = StairsDistractionFree.defaultValue
    #if os(macOS)
    // Driven by the pointer watcher; separate from the preference so the chrome can
    // come back without turning the mode off.
    @State private var chromeHidden = false
    #else
    // Touch-first: with the mode on the chrome rests hidden, and reveals are
    // transient — a tap on the top strip brings it back for a few seconds, and a
    // pointer (trackpad or Pencil) holds it while hovering the strip.
    @State private var chromeRevealed = false
    @State private var lastHoverY: CGFloat?
    @State private var chromeHideTask: Task<Void, Never>?
    #endif
    @State private var isSettingsPresented = false

    private var displayName: String {
        configuration.fileURL?.lastPathComponent ?? document.fileName
    }

    private var sectionColor: PlatformColor {
        PlatformColor.stairsColor(hexString: sectionColorHex) ?? StairsSectionColor.fallback
    }

    private var isDarkMode: Bool {
        observedTheme.resolvedColorScheme(systemColorScheme: systemColorScheme) == .dark
    }

    private var windowBackground: Color {
        isDarkMode ? .black : .white
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding {
            Self.columnVisibility(for: sidebarVisibility)
        } set: { newValue in
            sidebarVisibility = Self.rawValue(for: newValue)
        }
    }

    private var options: StepSceneOptions {
        StepSceneOptions(
            showsAxes: showsAxes,
            showsGrid: showsGrid,
            showsFloor: showsFloor,
            showsWireframe: showsWireframe,
            usesOriginalColors: usesOriginalColors,
            usesColoredAccentLights: usesColoredAccentLights
        )
    }

    private var optionsBinding: Binding<StepSceneOptions> {
        Binding {
            options
        } set: { newValue in
            showsAxes = newValue.showsAxes
            showsGrid = newValue.showsGrid
            showsFloor = newValue.showsFloor
            showsWireframe = newValue.showsWireframe
            usesOriginalColors = newValue.usesOriginalColors
            usesColoredAccentLights = newValue.usesColoredAccentLights
        }
    }

    private var hasMesh: Bool {
        if case .loaded(let model) = loader.phase {
            return model.mesh != nil
        }
        return false
    }

    private var isEmptyNewDocument: Bool {
        configuration.fileURL == nil && document.data.isEmpty
    }

    private var loadedModel: StepModel? {
        if case .loaded(let model) = loader.phase {
            return model
        }
        return nil
    }

    // Cross-sectioning needs real triangle geometry to clip and cap.
    private var canSection: Bool {
        hasMesh
    }

    // Gives a freshly loaded model a sensible default plane (through its center on
    // X) and keeps the offset within the model's extent as the axis changes.
    private func syncSection(to model: StepModel) {
        if sectionModelID != model.id {
            sectionModelID = model.id
            if !section.isEnabled {
                section.axis = .x
                section.offset = model.bounds.center.x
            }
        }
        section.clampOffset(to: model.bounds)
    }

    // Called when the user taps/clicks a surface point in "pick" mode.
    private func handlePickedSectionOffset(_ offset: Float) {
        section.offset = offset
        section.isEnabled = true
        isPickingSectionPoint = false
        if let model = loadedModel {
            section.clampOffset(to: model.bounds)
        }
    }

    // Measuring needs the precomputed snap geometry.
    private var canMeasure: Bool {
        hasMesh && snapModel != nil
    }

    private func handleMeasurePoint(_ point: StepMeasurePoint) {
        measurement.addPoint(point)
    }

    /// Replaces this empty document's contents with the bundled demo model. Each
    /// `StepFileDocument` carries a fresh id, so assigning one retriggers the
    /// loader's `.task(id: document.id)`.
    private func loadDemoModel() {
        do {
            document = try StairsDemoModel.document()
        } catch {
            modelErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Distraction-free chrome

    #if os(macOS)
    @ViewBuilder
    private var distractionFreeWatcher: some View {
        DistractionFreeChromeConfigurator(isEnabled: distractionFreeMode) { hidden in
            chromeHidden = hidden
        }
    }
    #else
    /// Hidden is the resting state; `chromeRevealed` marks a transient reveal.
    private var shouldHideChrome: Bool {
        distractionFreeMode && !chromeRevealed
    }

    private var distractionFreeToolbarVisibility: Visibility {
        shouldHideChrome ? .hidden : .visible
    }

    /// While the chrome is hidden, a strip along the top brings it back — by hover
    /// for a pointer, and by tap so a touch-only session is never stuck without it.
    @ViewBuilder
    private var distractionFreeRevealTarget: some View {
        if shouldHideChrome {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: StairsDistractionFree.revealHeight)
                .ignoresSafeArea(.container, edges: .top)
                .onTapGesture {
                    revealChrome()
                }
                .onContinuousHover { phase in
                    handleDistractionFreeHover(phase)
                }
        }
    }

    private func handleDistractionFreeHover(_ phase: HoverPhase) {
        guard distractionFreeMode else { return }
        switch phase {
        case .active(let location):
            lastHoverY = location.y
            if location.y <= StairsDistractionFree.revealHeight {
                cancelChromeHide()
                chromeRevealed = true
            } else if location.y >= StairsDistractionFree.revealHeight + StairsDistractionFree.revealHysteresis {
                scheduleChromeHide(after: StairsDistractionFree.hideDelay)
            }
        case .ended:
            // Crossing toolbar buttons emits transient `.ended` phases even while the
            // pointer is still in the reveal region. Only hide once the pointer has
            // actually been seen below the hysteresis band.
            if let lastHoverY,
               lastHoverY >= StairsDistractionFree.revealHeight + StairsDistractionFree.revealHysteresis {
                scheduleChromeHide(after: StairsDistractionFree.hideDelay)
            }
        }
    }

    /// A tap has no hover to hold the chrome up, so it stays for a few seconds and
    /// then hides again.
    private func revealChrome() {
        lastHoverY = 0
        chromeRevealed = true
        scheduleChromeHide(after: StairsDistractionFree.tapRevealDuration)
    }

    /// Toggling the mode always returns to its resting state: hidden when on
    /// (touch needs no pointer first), visible when off.
    private func handleDistractionFreeChange(_ enabled: Bool) {
        cancelChromeHide()
        lastHoverY = nil
        chromeRevealed = false
    }

    private func scheduleChromeHide(after delay: Duration) {
        guard chromeRevealed else { return }
        cancelChromeHide()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            chromeRevealed = false
        }
    }

    private func cancelChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
    }
    #endif

    /// The document's name without its extension, used to name exports.
    private var exportBaseName: String {
        let base = (displayName as NSString).deletingPathExtension
        return base.isEmpty ? "Model" : base
    }

    /// Whether there is tessellated geometry to write out.
    private var canExport: Bool {
        loadedModel?.mesh != nil
    }

    private func exportedData(_ format: StepExportFormat) -> Data? {
        guard let mesh = loadedModel?.mesh else { return nil }
        do {
            return try StepMeshExporter.data(for: mesh, format: format, modelName: exportBaseName)
        } catch {
            modelErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func exportModel(as format: StepExportFormat) {
        guard let data = exportedData(format) else { return }
        exportDocument = ExportedModelDocument(data: data)
        exportContentType = UTType(format.contentTypeIdentifier) ?? .data
        exportFilename = "\(exportBaseName).\(format.fileExtension)"
    }

    private func copyModel(as format: StepExportFormat) {
        guard let data = exportedData(format) else { return }
        let type = UTType(format.contentTypeIdentifier) ?? .data
        StairsClipboard.copy(data, as: type, includingText: format.isText)
    }

    /// Fills this empty document from the clipboard.
    private func pasteModel(from providers: [NSItemProvider]) async {
        guard let pasted = await StairsClipboard.document(from: providers) else {
            modelErrorMessage = "The clipboard doesn't contain a 3D model."
            return
        }
        document = pasted
    }

    // Builds (or clears) the snap model for the current model, off the main actor.
    private func rebuildSnapModel(for model: StepModel?) async {
        measurement.clearPoints()
        guard let model, let mesh = model.mesh else {
            snapModel = nil
            return
        }
        let center = model.bounds.center
        let built = await Task.detached(priority: .utility) {
            StepSnapModel(mesh: mesh, center: center)
        }.value
        guard loadedModel?.id == model.id else {
            return // a newer model loaded while we were building
        }
        snapModel = built
    }

    var body: some View {
        content
            // Scene-scoped, not view-scoped: `focusedValue` only publishes while the
            // view itself holds focus, which the document view never takes on
            // iPadOS — leaving `@FocusedValue` nil and the menu bar empty there.
            .focusedSceneValue(
                \.stepViewMenuState,
                StepViewMenuState(
                    options: optionsBinding,
                    canUseStepColors: hasMesh,
                    cameraProjection: $cameraProjection,
                    cameraState: $cameraState,
                    resetID: $resetID,
                    applyPrimaryView: { primaryViewRequest = StepPrimaryViewRequest(view: $0) },
                    section: $section,
                    canSection: canSection,
                    canCopyModel: !document.data.isEmpty,
                    copyModel: { StairsClipboard.copy(document) },
                    canExportModel: canExport,
                    exportModel: { exportModel(as: $0) },
                    copyModelAs: { copyModel(as: $0) }
                )
            )
            .fileExporter(
                isPresented: Binding {
                    exportDocument != nil
                } set: { presented in
                    if !presented {
                        exportDocument = nil
                    }
                },
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                exportDocument = nil
                if case .failure(let error) = result {
                    modelErrorMessage = error.localizedDescription
                }
            }
            .alert(
                "Unable to Open Model",
                isPresented: Binding {
                    modelErrorMessage != nil
                } set: { presented in
                    if !presented {
                        modelErrorMessage = nil
                    }
                },
                presenting: modelErrorMessage
            ) { _ in
                Button("OK", role: .cancel) { modelErrorMessage = nil }
            } message: { message in
                Text(message)
            }
            .task(id: document.id) {
                if isEmptyNewDocument {
                    loader.reset()
                } else {
                    if cameraState == nil {
                        cameraState = Self.decodedCameraState(cameraStateStore)
                    }
                    loader.load(data: document.data, fileName: displayName)
                }
            }
            .onChange(of: loadedModel?.id) { _, _ in
                if let model = loadedModel {
                    syncSection(to: model)
                }
            }
            .onChange(of: section.axis) { _, _ in
                // Re-center on the new axis so an enabled plane still cuts the model.
                if let model = loadedModel {
                    section.offset = model.bounds.center[section.axis.index]
                    section.clampOffset(to: model.bounds)
                }
            }
            .task(id: loadedModel?.id) {
                await rebuildSnapModel(for: loadedModel)
            }
            .onChange(of: measurement.isActive) { _, active in
                // Measuring and section point-picking are mutually exclusive tools.
                if active {
                    isPickingSectionPoint = false
                }
            }
            .onChange(of: isPickingSectionPoint) { _, picking in
                if picking {
                    measurement.isActive = false
                }
            }
            .onChange(of: cameraState) { _, newValue in
                cameraStateStore = Self.encodedCameraState(newValue)
            }
            .onAppear {
                observedTheme = StairsTheme.stored
            }
            .onChange(of: theme) { _, newTheme in
                observedTheme = newTheme
            }
            .onReceive(NotificationCenter.default.publisher(for: .stairsThemeDidChange)) { notification in
                observedTheme = StairsTheme.theme(from: notification) ?? StairsTheme.stored
            }
            .onDisappear {
                loader.cancel()
            }
    }

    @ToolbarContentBuilder
    private var documentToolbar: some ToolbarContent {
        #if os(macOS)
        // One toolbar item, so everything shares a single capsule. Previously the
        // picker sat in its own group and drew a second capsule — which stayed on
        // screen, empty, whenever the picker was hidden to hold its place.
        ToolbarItem {
            HStack(spacing: 10) {
                // The cut axis appears only while a section is active. It can be
                // added and removed freely now: toolbar items are trailing-aligned,
                // so this capsule grows leftward and the buttons keep their places.
                if section.isEnabled {
                    sectionAxisPicker
                        // Fixed, or the segmented picker stretches to fill the toolbar.
                        .frame(width: 108)
                }

                crossSectionButton
                measureButton
                fitButton
            }
            // Inside a plain HStack a Label would draw its title as well; toolbar
            // items are icon-only.
            .labelStyle(.iconOnly)
        }
        #else
        // One item per control. Each button is a plain image item the system can
        // lay out on either bar axis — iPhone Duo folds them into its vertical
        // bar, which drops custom-view items such as one HStack holding them all.
        // The adjacent trailing items still share a single capsule.
        //
        // The cut axis appears only while a section is active. A segmented control
        // is horizontal-only, so a vertical bar leaves it out; the inspector's
        // Plane picker sets the axis there.
        if section.isEnabled {
            ToolbarItem(placement: .principal) {
                sectionAxisPicker
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            crossSectionButton
        }

        ToolbarItem(placement: .topBarTrailing) {
            measureButton
        }

        ToolbarItem(placement: .topBarTrailing) {
            fitButton
        }

        ToolbarItem(placement: .topBarTrailing) {
            shareMenu
        }

        ToolbarItem(placement: .topBarTrailing) {
            settingsButton
        }
        #endif
    }

    private var sectionAxisPicker: some View {
        Picker("Section Axis", selection: $section.axis) {
            ForEach(StepSectionAxis.allCases, id: \.self) { axis in
                Text(axis.displayName).tag(axis)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Cross section axis")
        .disabled(!canSection)
    }

    private var crossSectionButton: some View {
        Button {
            toggleSection()
        } label: {
            Label(
                "Cross Section",
                systemImage: section.isEnabled ? "square.split.2x1.fill" : "square.split.2x1"
            )
        }
        .help("Cross section")
        .disabled(!canSection)
    }

    private var measureButton: some View {
        Button {
            toggleMeasure()
        } label: {
            Label("Measure", systemImage: measurement.isActive ? "ruler.fill" : "ruler")
        }
        .help("Measure distance")
        .disabled(!canMeasure)
    }

    private var fitButton: some View {
        Button {
            cameraState = nil
            resetID = UUID()
        } label: {
            Label("Fit", systemImage: "viewfinder")
        }
        .help("Fit model")
    }

    #if !os(macOS)
    // iOS has no menu bar to carry Copy/Export As, so sharing lives in the
    // toolbar: the original file verbatim, or a mesh conversion in any export
    // format.
    private var shareMenu: some View {
        Menu {
            ShareLink(
                item: SharedModelFile(filename: displayName, content: .original(document.data)),
                preview: SharePreview(displayName)
            ) {
                Text("Share Model")
            }
            .disabled(document.data.isEmpty)

            // Mirrors the Export As menu: one entry per format, disabled without
            // tessellated geometry — ShareLink needs its payload up front, so the
            // placeholder buttons hold the shape.
            if let mesh = loadedModel?.mesh {
                ForEach(StepExportFormat.allCases) { format in
                    ShareLink(
                        item: SharedModelFile(
                            filename: "\(exportBaseName).\(format.fileExtension)",
                            content: .export(mesh: mesh, format: format, modelName: exportBaseName)
                        ),
                        preview: SharePreview("\(exportBaseName).\(format.fileExtension)")
                    ) {
                        Text("Share as \(format.displayName)")
                    }
                }
            } else {
                ForEach(StepExportFormat.allCases) { format in
                    Button("Share as \(format.displayName)") {}
                        .disabled(true)
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Share model")
    }

    // iOS has no Settings scene, so preferences open from the toolbar.
    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
        .keyboardShortcut(",", modifiers: .command)
    }
    #endif

    private func toggleMeasure() {
        // Deliberately does not reveal the inspector: measuring happens directly on
        // the model, and the floating label already reports the distance.
        measurement.isActive.toggle()
    }

    private func toggleSection() {
        // Like the measure tool, this leaves the sidebar alone: the axis picker sits
        // in the toolbar and the plane itself is dragged directly in the viewport.
        section.isEnabled.toggle()
        if section.isEnabled {
            if let model = loadedModel {
                syncSection(to: model)
            }
        } else {
            isPickingSectionPoint = false
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // A plain view background, deliberately NOT
        // `.containerBackground(_, for: .window)`: that paints the titlebar
        // region too, and SwiftUI achieves it by holding the titlebar
        // transparent — which suppresses the standard toolbar material no
        // matter what the window or the toolbar modifiers say. The canvas
        // still reaches the top edge via `.fullSizeContentView`.
        let base = navigationContent
            .frame(minWidth: 160, minHeight: 160)
            .background(WindowChromeConfigurator())
            .background(distractionFreeWatcher)
            .background(windowBackground)
        // The availability guard is for the SwiftPM dev build (its floor is
        // macOS 14); the app itself deploys far above it.
        if #available(macOS 15.0, *) {
            base
                // The system's own toolbar material, except while distraction-free
                // has auto-hidden the chrome — then the background goes too, so no
                // empty bar is left floating over the model.
                .toolbarBackgroundVisibility(chromeHidden ? .hidden : .automatic, for: .windowToolbar)
        } else {
            base
        }
        #else
        navigationContent
            .sheet(isPresented: $isSettingsPresented) {
                StairsIOSSettingsView()
            }
        #endif
    }

    private var navigationContent: some View {
        NavigationSplitView(
            columnVisibility: columnVisibilityBinding,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            StepInspectorView(
                displayName: displayName,
                fileURL: configuration.fileURL,
                byteCount: document.data.count,
                phase: loader.phase,
                section: $section,
                canSection: canSection,
                isPickingSectionPoint: $isPickingSectionPoint,
                measurement: $measurement,
                onShowModelView: showModelColumn
            )
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            modelDetail
                #if os(macOS)
                .background(windowBackground)
                #endif
                .navigationTitle(detailNavigationTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    documentToolbar
                }
                // Toggled by *value* rather than with an `if`, so the SceneKit view
                // underneath isn't torn down and rebuilt on every reveal.
                #if os(macOS)
                .toolbar(chromeHidden ? .hidden : .visible, for: .windowToolbar)
                #else
                .toolbar(distractionFreeToolbarVisibility, for: .navigationBar)
                .onContinuousHover { phase in
                    handleDistractionFreeHover(phase)
                }
                // Not a sidebar control: it only restores the hidden bar, which is
                // what carries the system sidebar toggle and back button.
                .overlay(alignment: .top) {
                    distractionFreeRevealTarget
                }
                .animation(.easeInOut(duration: 0.18), value: shouldHideChrome)
                .onChange(of: distractionFreeMode) { _, enabled in
                    handleDistractionFreeChange(enabled)
                }
                #endif
        }
        .fullBleedDocumentChrome()
    }

    // On iPhone (compact) the model view and inspector are separate stacked
    // screens, so the inspector carries the document name and the model view
    // shows no title — a titled detail would add a second navigation bar (and a
    // second back button). On iPad/macOS the columns are visible together and
    // the detail keeps the document name.
    private var detailNavigationTitle: String {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            return ""
        }
        #endif
        return displayName
    }

    private func showModelColumn() {
        preferredCompactColumn = .detail
    }

    private var modelDetail: some View {
        GeometryReader { proxy in
            detailContent(safeAreaInsets: proxy.safeAreaInsets)
                #if os(macOS)
                .ignoresSafeArea(.container, edges: [.top, .leading])
                #else
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                #endif
        }
    }

    // Shows a determinate bar once the importer reports progress (large STEP
    // files), and an indeterminate spinner before the first update.
    @ViewBuilder
    private var loadingIndicator: some View {
        if loader.progress > 0 {
            VStack(spacing: 10) {
                ProgressView(value: loader.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text("Loading \(Int(loader.progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private func detailContent(safeAreaInsets: EdgeInsets) -> some View {
        if isEmptyNewDocument {
            ContentUnavailableView {
                Label("Open a 3D Model", systemImage: "doc.viewfinder")
            } description: {
                Text("Open a model file, or load the bundled demo.")
            } actions: {
                // Loads in-process, where this app's own bundle is always reachable.
                // The launch scene's demo button runs in a sandboxed host process,
                // which is where seeding a new document has gone wrong.
                Button("Open Demo Model") {
                    loadDemoModel()
                }
                // A new document starts empty, so the clipboard is a real way to
                // fill it. PasteButton is system-mediated: it disables itself when
                // the clipboard holds nothing usable, and reads it without the
                // permission prompt a direct pasteboard read would trigger on iOS.
                PasteButton(supportedContentTypes: StairsClipboard.supportedContentTypes) { providers in
                    Task { await pasteModel(from: providers) }
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(windowBackground)
        } else {
            switch loader.phase {
            case .idle, .loading:
                loadingIndicator
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(windowBackground)
            case .failed(let message):
                ContentUnavailableView(
                    "Unable to Open Model",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(windowBackground)
            case .loaded(let model):
                LoadedStepSceneView(
                    model: model,
                    options: options,
                    resetID: resetID,
                    projection: cameraProjection,
                    primaryViewRequest: primaryViewRequest,
                    isDarkMode: isDarkMode,
                    reverseHorizontalRotation: reverseHorizontalRotation,
                    reverseVerticalRotation: reverseVerticalRotation,
                    safeAreaInsets: safeAreaInsets,
                    section: section,
                    sectionColor: sectionColor,
                    isPickingSectionPoint: isPickingSectionPoint,
                    onSectionOffsetPicked: handlePickedSectionOffset,
                    measurement: measurement,
                    snapModel: snapModel,
                    onMeasurePointPicked: handleMeasurePoint,
                    onMeasureEscape: { measurement.clearPoints() },
                    cameraState: $cameraState
                )
                // Only a new model resets this view's state (and its camera). Option,
                // theme, and reset-token changes rebuild the scene in place via
                // `.task(id:)`, keeping the current scene visible while it builds.
                .id(model.id)
            }
        }
    }

    private static func encodedCameraState(_ state: StepSceneCameraState?) -> String {
        guard let state, state.isValid,
              let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private static func decodedCameraState(_ json: String) -> StepSceneCameraState? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(StepSceneCameraState.self, from: data),
              state.isValid else {
            return nil
        }
        return state
    }

    private static func columnVisibility(for rawValue: String) -> NavigationSplitViewVisibility {
        switch rawValue {
        case "all":
            return .all
        case "automatic":
            return .automatic
        case "doubleColumn":
            return .doubleColumn
        default:
            return .detailOnly
        }
    }

    private static func rawValue(for columnVisibility: NavigationSplitViewVisibility) -> String {
        switch columnVisibility {
        case .all:
            return "all"
        case .automatic:
            return "automatic"
        case .doubleColumn:
            return "doubleColumn"
        case .detailOnly:
            return "detailOnly"
        default:
            return "detailOnly"
        }
    }
}

private extension View {
    // Make the navigation/window chrome background transparent so the document
    // surface reads full-bleed beneath it. (macOS chrome is configured
    // separately in `content`.)
    @ViewBuilder
    func fullBleedDocumentChrome() -> some View {
        #if os(macOS)
        self
        #else
        // The standard bar material, explicitly: over a non-scrolling canvas the
        // bar shows its scroll-edge appearance, which is fully transparent — so
        // `.automatic` would look just like the old forced `.hidden`. When
        // distraction-free auto-hides the chrome the whole bar goes with it, so
        // nothing is left to need transparency.
        toolbarBackground(.visible, for: .navigationBar)
        #endif
    }
}

private struct PreparedStepScene {
    var id = UUID()
    var presentation: StepScenePresentation

    var scene: SCNScene {
        presentation.scene
    }

    var cameraNode: SCNNode {
        presentation.cameraNode
    }

    init(presentation: StepScenePresentation) {
        self.presentation = presentation
    }
}

// Carries a presentation built off the main actor back to it. The SceneKit
// objects are only created (off-main) and then read (on-main) — never touched
// concurrently — so the unchecked Sendable conformance is sound. `nonisolated`
// so it can be constructed inside the background build task.
private nonisolated struct SendableScenePresentation: @unchecked Sendable {
    let value: StepScenePresentation
}

private struct LoadedStepSceneIdentity: Hashable {
    var modelID: UUID
    var options: StepSceneOptions
    var isDarkMode: Bool
    var resetID: UUID
}

private struct LoadedStepSceneView: View {
    var model: StepModel
    var options: StepSceneOptions
    var resetID: UUID
    var projection: StepCameraProjection
    var primaryViewRequest: StepPrimaryViewRequest?
    var isDarkMode: Bool
    var reverseHorizontalRotation: Bool
    var reverseVerticalRotation: Bool
    var safeAreaInsets: EdgeInsets
    var section: StepSectionPlane
    var sectionColor: PlatformColor
    var isPickingSectionPoint: Bool
    var onSectionOffsetPicked: (Float) -> Void
    var measurement: StepMeasurement
    var snapModel: StepSnapModel?
    var onMeasurePointPicked: (StepMeasurePoint) -> Void
    var onMeasureEscape: () -> Void
    @Binding var cameraState: StepSceneCameraState?

    // Built off the main actor so large meshes don't freeze the UI. `.task(id:)`
    // rebuilds it when the model, options, theme, or reset token change; the
    // previous scene stays on screen until the new one is ready (no flash).
    @State private var preparedScene: PreparedStepScene? = nil
    @AppStorage("useRealityKitRenderer") private var useRealityKitRenderer = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                isDarkMode ? Color.black : Color.white

                if useRealityKitRenderer, let mesh = model.mesh {
                    RealityStepCanvas(
                        mesh: mesh,
                        options: options,
                        isDarkMode: isDarkMode,
                        reverseHorizontalRotation: reverseHorizontalRotation,
                        reverseVerticalRotation: reverseVerticalRotation,
                        projection: projection,
                        resetID: resetID,
                        primaryViewRequest: primaryViewRequest,
                        section: section,
                        sectionColor: sectionColor,
                        measurement: measurement,
                        snapModel: snapModel,
                        onMeasurePointPicked: onMeasurePointPicked,
                        onMeasureEscape: onMeasureEscape,
                        cameraState: $cameraState
                    )
                    .id(model.id)

                    // The RealityKit host publishes its first state right after
                    // framing, so the fallback transform is never consulted.
                    if cameraState?.isValid == true {
                        StepLengthScaleBar(
                            size: proxy.size,
                            safeAreaInsets: safeAreaInsets,
                            cameraState: cameraState,
                            projection: projection,
                            fallbackCameraTransform: SCNMatrix4Identity,
                            fieldOfView: 48,
                            orthographicScale: cameraState?.orthographicScale,
                            isDarkMode: isDarkMode
                        )
                        .allowsHitTesting(false)
                    }
                } else if let preparedScene {
                    sceneContent(preparedScene, proxy: proxy)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: sceneBuildID) {
            await buildScene()
        }
    }

    @ViewBuilder
    private func sceneContent(_ prepared: PreparedStepScene, proxy: GeometryProxy) -> some View {
        let viewport = sceneViewportLayout(for: proxy.size)

        StepSceneCanvas(
            presentation: prepared.presentation,
            projection: projection,
            isDarkMode: isDarkMode,
            reverseHorizontalRotation: reverseHorizontalRotation,
            reverseVerticalRotation: reverseVerticalRotation,
            interactionInsets: safeAreaInsets,
            primaryViewRequest: primaryViewRequest,
            section: section,
            sectionSourceMesh: model.mesh,
            sectionColor: sectionColor,
            boundsCenter: model.bounds.center,
            modelID: model.id,
            isPickingSectionPoint: isPickingSectionPoint,
            onSectionOffsetPicked: onSectionOffsetPicked,
            measurement: measurement,
            snapModel: snapModel,
            onMeasurePointPicked: onMeasurePointPicked,
            onMeasureEscape: onMeasureEscape,
            cameraState: $cameraState
        )
        .id(prepared.id)
        .frame(width: viewport.size.width, height: viewport.size.height)
        .offset(x: viewport.offset.width, y: viewport.offset.height)
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()

        StepLengthScaleBar(
            size: viewport.size,
            safeAreaInsets: safeAreaInsets,
            cameraState: cameraState,
            projection: projection,
            fallbackCameraTransform: prepared.cameraNode.transform,
            fieldOfView: prepared.cameraNode.camera?.fieldOfView ?? 48,
            orthographicScale: cameraState?.orthographicScale ?? prepared.cameraNode.camera?.orthographicScale,
            isDarkMode: isDarkMode
        )
        .allowsHitTesting(false)
    }

    private var sceneBuildID: LoadedStepSceneIdentity {
        LoadedStepSceneIdentity(modelID: model.id, options: options, isDarkMode: isDarkMode, resetID: resetID)
    }

    private func buildScene() async {
        let model = model
        let options = options
        let isDarkMode = isDarkMode
        let boxed = await Task.detached(priority: .userInitiated) {
            SendableScenePresentation(
                value: StepSceneFactory.presentation(for: model, options: options, isDarkMode: isDarkMode)
            )
        }.value
        guard !Task.isCancelled else {
            return
        }
        preparedScene = PreparedStepScene(presentation: boxed.value)
    }

    private func sceneViewportLayout(for size: CGSize) -> (size: CGSize, offset: CGSize) {
        let offset = CGSize(
            width: (safeAreaInsets.leading - safeAreaInsets.trailing) / 2,
            height: (safeAreaInsets.top - safeAreaInsets.bottom) / 2
        )

        return (
            size: CGSize(
                width: max(size.width + abs(offset.width) * 2, 1),
                height: max(size.height + abs(offset.height) * 2, 1)
            ),
            offset: offset
        )
    }
}

private struct StepLengthScaleBar: View {
    var size: CGSize
    var safeAreaInsets: EdgeInsets
    var cameraState: StepSceneCameraState?
    var projection: StepCameraProjection
    var fallbackCameraTransform: SCNMatrix4
    var fieldOfView: CGFloat
    var orthographicScale: Double?
    var isDarkMode: Bool

    var body: some View {
        if let metrics = metrics {
            VStack(alignment: .leading, spacing: 5) {
                Text(metrics.label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(foregroundColor.opacity(0.74))

                Canvas { context, size in
                    var path = Path()
                    let y = size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: metrics.screenLength, y: y))
                    path.move(to: CGPoint(x: 0, y: y - 4))
                    path.addLine(to: CGPoint(x: 0, y: y + 4))
                    path.move(to: CGPoint(x: metrics.screenLength, y: y - 4))
                    path.addLine(to: CGPoint(x: metrics.screenLength, y: y + 4))

                    context.stroke(
                        path,
                        with: .color(foregroundColor.opacity(0.56)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                }
                .frame(width: metrics.screenLength, height: 10)
            }
            .padding(.leading, safeAreaInsets.leading + 14)
            .padding(.bottom, safeAreaInsets.bottom + 18)
        }
    }

    private struct Metrics {
        var screenLength: CGFloat
        var label: String
    }

    private var foregroundColor: Color {
        isDarkMode ? .white : .black
    }

    private var metrics: Metrics? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        let targetScreenLength = min(max(size.width * 0.12, 72), 120)
        let visibleHeight = visibleWorldHeight()
        let worldUnitsPerPoint = visibleHeight / max(Double(size.height), 1)
        let worldLength = niceScaleLength(worldUnitsPerPoint * Double(targetScreenLength))
        let screenLength = CGFloat(worldLength / worldUnitsPerPoint)

        guard screenLength >= 24, screenLength.isFinite else {
            return nil
        }

        return Metrics(screenLength: screenLength, label: scaleLabel(forMillimeters: worldLength))
    }

    private func visibleWorldHeight() -> Double {
        if projection == .orthographic,
           let orthographicScale,
           orthographicScale.isFinite,
           orthographicScale > 0 {
            // SCNCamera.orthographicScale is HALF the visible height (pixel
            // verified against both engines in the RealityKit spike rig).
            return orthographicScale * 2
        }

        let distance = cameraDistance()
        let fieldOfViewRadians = Double(fieldOfView) * .pi / 180
        return 2 * distance * tan(fieldOfViewRadians / 2)
    }

    private func cameraDistance() -> Double {
        let transform = cameraState?.isValid == true
            ? cameraState?.transform ?? fallbackTransformValues
            : fallbackTransformValues
        let position = SIMD3<Double>(
            Double(transform[12]),
            Double(transform[13]),
            Double(transform[14])
        )
        let forward = normalized(SIMD3<Double>(
            -Double(transform[8]),
            -Double(transform[9]),
            -Double(transform[10])
        ))
        let distanceToOriginPlane = dot(-position, forward)
        let fallbackDistance = max(length(position), 1)
        return max(distanceToOriginPlane.isFinite && distanceToOriginPlane > 0 ? distanceToOriginPlane : fallbackDistance, 1)
    }

    private var fallbackTransformValues: [Float] {
        [
            Float(fallbackCameraTransform.m11), Float(fallbackCameraTransform.m12),
            Float(fallbackCameraTransform.m13), Float(fallbackCameraTransform.m14),
            Float(fallbackCameraTransform.m21), Float(fallbackCameraTransform.m22),
            Float(fallbackCameraTransform.m23), Float(fallbackCameraTransform.m24),
            Float(fallbackCameraTransform.m31), Float(fallbackCameraTransform.m32),
            Float(fallbackCameraTransform.m33), Float(fallbackCameraTransform.m34),
            Float(fallbackCameraTransform.m41), Float(fallbackCameraTransform.m42),
            Float(fallbackCameraTransform.m43), Float(fallbackCameraTransform.m44)
        ]
    }

    private func niceScaleLength(_ rawLength: Double) -> Double {
        guard rawLength > 0, rawLength.isFinite else {
            return 1
        }

        let magnitude = pow(10, floor(log10(rawLength)))
        let normalized = rawLength / magnitude
        let nice: Double
        if normalized < 2 {
            nice = 1
        } else if normalized < 5 {
            nice = 2
        } else {
            nice = 5
        }
        return nice * magnitude
    }

    private func scaleLabel(forMillimeters millimeters: Double) -> String {
        if millimeters >= 1_000 {
            return "\((millimeters / 1_000).formatted(.number.precision(.fractionLength(0...2)))) m"
        }
        if millimeters >= 10 {
            return "\(millimeters.formatted(.number.precision(.fractionLength(0)))) mm"
        }
        if millimeters >= 1 {
            return "\(millimeters.formatted(.number.precision(.fractionLength(1)))) mm"
        }
        return "\((millimeters * 1_000).formatted(.number.precision(.fractionLength(0)))) um"
    }

    private func length(_ vector: SIMD3<Double>) -> Double {
        sqrt(dot(vector, vector))
    }

    private func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let vectorLength = length(vector)
        guard vectorLength > 0 else {
            return SIMD3<Double>(0, 0, -1)
        }
        return vector / vectorLength
    }
}

private struct StepInspectorView: View {
    var displayName: String
    var fileURL: URL?
    var byteCount: Int
    var phase: StepSceneLoader.Phase
    @Binding var section: StepSectionPlane
    var canSection: Bool
    @Binding var isPickingSectionPoint: Bool
    @Binding var measurement: StepMeasurement
    var onShowModelView: () -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if !os(macOS)
    @AppStorage(StairsSectionColor.storageKey) private var sectionColorHex = StairsSectionColor.defaultHex
    #endif

    var body: some View {
        List {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                Section {
                    Button(action: onShowModelView) {
                        HStack {
                            Label("Model view", systemImage: "cube")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            #endif

            Section("File") {
                LabeledContent("Name", value: displayName)
                if let fileURL {
                    LabeledContent("Location", value: fileURL.deletingLastPathComponent().path)
                }
                LabeledContent("Size", value: byteCount.formatted(.byteCount(style: .file)))
            }

            Section("Geometry") {
                switch phase {
                case .loaded(let model):
                    LabeledContent("Import", value: model.importMode.rawValue)
                    LabeledContent("Vertices", value: model.vertexCount.formatted())
                    LabeledContent("Triangles", value: model.triangleCount.formatted())
                    LabeledContent("Materials", value: model.materialCount.formatted())
                    LabeledContent("Width", value: dimensionString(model.bounds.width))
                    LabeledContent("Height", value: dimensionString(model.bounds.height))
                    LabeledContent("Depth", value: dimensionString(model.bounds.depth))
                case .failed:
                    LabeledContent("Import", value: "Failed")
                case .idle, .loading:
                    LabeledContent("Import", value: "Loading")
                }
            }

            if case .loaded(let model) = phase, model.mesh != nil {
                crossSectionSection(for: model)
                measureSection
            }
        }
        // On iPhone (compact) the inspector is its own screen, so it carries the
        // document name as its title; the model view shows none.
        .navigationTitle(navigationTitleText)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .fullBleedDocumentChrome()
    }

    @ViewBuilder
    private func crossSectionSection(for model: StepModel) -> some View {
        Section("Cross Section") {
            Toggle("Enable", isOn: $section.isEnabled)
                .disabled(!canSection)

            if section.isEnabled {
                Picker("Plane", selection: $section.axis) {
                    ForEach(StepSectionAxis.allCases, id: \.self) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Position") {
                    HStack(spacing: 4) {
                        TextField(
                            "Position",
                            value: offsetBinding(for: model),
                            format: .number.precision(.fractionLength(0...3))
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 76)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        Text("mm")
                            .foregroundStyle(.secondary)
                    }
                }

                if let range = offsetRange(for: model) {
                    Slider(value: offsetBinding(for: model), in: range)
                }

                Button {
                    togglePointPicking()
                } label: {
                    Label(
                        isPickingSectionPoint ? "Tap a Point on the Model…" : "Pick Point on Model",
                        systemImage: isPickingSectionPoint ? "hand.point.up.left.fill" : "hand.point.up.left"
                    )
                }

                Toggle("Flip Side", isOn: $section.isFlipped)
                Toggle("Solid Cap", isOn: $section.showsCap)

                #if !os(macOS)
                // On macOS this lives in the Settings window, but SwiftUI's
                // `Settings` scene is macOS-only, so iPad reaches it here.
                ColorPicker("Cut Face Fill", selection: sectionColorBinding, supportsOpacity: false)
                #endif
            }
        }
        .disabled(!canSection)
    }

    #if !os(macOS)
    private var sectionColorBinding: Binding<Color> {
        Binding {
            Color(PlatformColor.stairsColor(hexString: sectionColorHex) ?? StairsSectionColor.fallback)
        } set: { newValue in
            sectionColorHex = PlatformColor(newValue).stairsHexString
        }
    }
    #endif

    private func togglePointPicking() {
        isPickingSectionPoint.toggle()
        #if os(iOS)
        // The model canvas is a separate screen on iPhone; surface it to tap on.
        if isPickingSectionPoint, horizontalSizeClass == .compact {
            onShowModelView()
        }
        #endif
    }

    private func offsetBinding(for model: StepModel) -> Binding<Double> {
        Binding(
            get: { Double(section.offset) },
            set: { newValue in
                section.offset = Float(newValue)
                section.clampOffset(to: model.bounds)
            }
        )
    }

    private func offsetRange(for model: StepModel) -> ClosedRange<Double>? {
        let lower = Double(model.bounds.minValue(axis: section.axis))
        let upper = Double(model.bounds.maxValue(axis: section.axis))
        guard lower.isFinite, upper.isFinite, upper > lower else {
            return nil
        }
        return lower...upper
    }

    // Measuring is turned on from the toolbar ruler button; this section only
    // surfaces its options and readout while the tool is in use.
    @ViewBuilder
    private var measureSection: some View {
        if measurement.isActive || measurement.start != nil {
            Section("Measure") {
                switch measurement.readout {
                case .edgeLength(let distance, _)?:
                    LabeledContent("Edge length", value: measureLengthString(distance))
                    Text("Select a second edge to measure between them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .pointToPoint(let distance, let delta)?:
                    LabeledContent("Distance", value: measureLengthString(distance))
                    LabeledContent("ΔX", value: measureLengthString(abs(delta.x)))
                    LabeledContent("ΔY", value: measureLengthString(abs(delta.y)))
                    LabeledContent("ΔZ", value: measureLengthString(abs(delta.z)))
                case .normalDistance(let distance, _, _)?:
                    LabeledContent("Normal distance", value: measureLengthString(distance))
                case .notParallel(let angle)?:
                    Label {
                        Text("Selected surfaces/edges are not parallel (\(angle.formatted(.number.precision(.fractionLength(0...1))))° apart).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                case nil:
                    if measurement.isActive {
                        Text(measurement.start == nil
                             ? "Click two points, surfaces, or edges."
                             : "Click the second point, surface, or edge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if measurement.start != nil {
                    Button("Clear Measurement") {
                        measurement.clearPoints()
                    }
                }
            }
        }
    }

    private func measureLengthString(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...3))) + " mm"
    }

    private var navigationTitleText: String {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            return displayName
        }
        #endif
        return "Info"
    }

    private func dimensionString(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(0...3))) + " mm"
    }
}

#if os(macOS)
private struct WindowChromeConfigurator: NSViewRepresentable {
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("StairsDocumentWindow")
    private static let defaultContentSize = NSSize(width: 400, height: 400)
    private static let minimumContentSize = NSSize(width: 160, height: 160)

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView()
    }

    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.configureWindow()
    }

    final class ConfiguringView: NSView {
        private weak var configuredWindow: NSWindow?
        private var didApplyInitialFrame = false
        private var didActivateApplication = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configuredWindow = nil
            didApplyInitialFrame = false
            configureWindow()
        }

        func configureWindow() {
            guard let window else {
                return
            }

            // Full-size content keeps the canvas bleeding under the toolbar, but the
            // titlebar is NOT made transparent: that flag suppresses the standard
            // toolbar material at the AppKit level, beneath anything SwiftUI's
            // toolbar-background modifiers can say. Distraction-free flips it
            // transiently while the chrome is auto-hidden (see StairsDistractionFree).
            window.styleMask.insert(.fullSizeContentView)
            window.contentMinSize = WindowChromeConfigurator.minimumContentSize
            activateApplicationOnce()

            if configuredWindow !== window {
                configuredWindow = window
                didApplyInitialFrame = false
            }

            guard !didApplyInitialFrame else {
                return
            }

            didApplyInitialFrame = true
            let restoredFrame = window.setFrameUsingName(WindowChromeConfigurator.frameAutosaveName)
            window.setFrameAutosaveName(WindowChromeConfigurator.frameAutosaveName)

            if !restoredFrame {
                setDefaultContentSize(for: window)
            }
        }

        private func setDefaultContentSize(for window: NSWindow) {
            let targetContentSize = WindowChromeConfigurator.defaultContentSize
            let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize)).size
            let currentFrame = window.frame
            let centeredFrame = NSRect(
                x: currentFrame.midX - targetFrameSize.width / 2,
                y: currentFrame.midY - targetFrameSize.height / 2,
                width: targetFrameSize.width,
                height: targetFrameSize.height
            )
            window.setFrame(centeredFrame, display: true)
        }

        private func activateApplicationOnce() {
            guard !didActivateApplication else {
                return
            }

            didActivateApplication = true
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
#endif
