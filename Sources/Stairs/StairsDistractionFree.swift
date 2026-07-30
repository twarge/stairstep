import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Distraction-free mode: the window's chrome hides itself so only the model is
/// on screen, and comes back when the pointer returns to the top of the window.
enum StairsDistractionFree {
    static let storageKey = "distractionFreeMode"
    static let defaultValue = false

    /// How close to the top of the window the pointer must be for the chrome to
    /// show, and how much further it must fall before the chrome hides again.
    /// The hysteresis stops the toolbar strobing along the edge of the strip.
    static let revealHeight: CGFloat = 92
    static let revealHysteresis: CGFloat = 48
    /// The hide is debounced: revealing the toolbar shifts the strip slightly and
    /// crossing toolbar items emits stray excursions, so let those settle first.
    static let hideDelay: Duration = .milliseconds(350)
    /// Touch has no hover, so a tap-reveal keeps the chrome up long enough to use
    /// the toolbar, then hides it again.
    static let tapRevealDuration: Duration = .seconds(4)
}

#if os(macOS)
/// Watches the pointer and reports when the window chrome should hide.
///
/// The tracking area is installed on the window's *content view* rather than on
/// this view, so it sees the pointer anywhere in the window — including over the
/// toolbar itself, which is exactly the region that has to keep the chrome up.
struct DistractionFreeChromeConfigurator: NSViewRepresentable {
    var isEnabled: Bool
    /// Fires whenever the auto-hide state flips. The view layer reacts by toggling
    /// the toolbar *by value* (`.toolbar(_:for:)`) rather than with an `if`, so
    /// SwiftUI doesn't tear down and rebuild the scene view on every reveal.
    var onChromeHiddenChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        ChromeView(isEnabled: isEnabled, onChromeHiddenChange: onChromeHiddenChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let chromeView = nsView as? ChromeView else {
            return
        }
        chromeView.onChromeHiddenChange = onChromeHiddenChange
        chromeView.isEnabled = isEnabled
    }

    final class ChromeView: NSView {
        var isEnabled: Bool {
            didSet {
                guard oldValue != isEnabled else { return }
                applyMode()
            }
        }

        var onChromeHiddenChange: (Bool) -> Void

        private weak var configuredWindow: NSWindow?
        private weak var trackingView: NSView?
        private var trackingArea: NSTrackingArea?
        private var isChromeHidden = false
        private var hideTask: Task<Void, Never>?

        init(isEnabled: Bool, onChromeHiddenChange: @escaping (Bool) -> Void) {
            self.isEnabled = isEnabled
            self.onChromeHiddenChange = onChromeHiddenChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // Leaving the hierarchy: drop the tracking area rather than leave it
                // attached to a content view we no longer follow.
                removeTrackingArea()
                cancelPendingHide()
                return
            }
            applyMode()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyMode()
        }

        private func applyMode() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncConfiguredWindow()

                guard self.isEnabled else {
                    self.removeTrackingArea()
                    self.restoreWindowChrome()
                    return
                }

                self.installTrackingAreaIfNeeded()
                self.updateChromeVisibilityForCurrentPointer()
            }
        }

        private func syncConfiguredWindow() {
            guard configuredWindow !== window else { return }
            removeTrackingArea()
            restoreWindowChrome()
            configuredWindow = window
            isChromeHidden = false
        }

        private func installTrackingAreaIfNeeded() {
            guard let contentView = configuredWindow?.contentView else { return }
            guard trackingArea == nil || trackingView !== contentView else { return }
            removeTrackingArea()

            let options: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .enabledDuringMouseDrag,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            contentView.addTrackingArea(area)
            trackingArea = area
            trackingView = contentView
        }

        private func removeTrackingArea() {
            if let trackingArea, let trackingView {
                trackingView.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            trackingView = nil
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            updateChromeVisibility(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            updateChromeVisibility(for: event)
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            updateChromeVisibility(for: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            super.rightMouseDragged(with: event)
            updateChromeVisibility(for: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            super.otherMouseDragged(with: event)
            updateChromeVisibility(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            updateChromeVisibility(for: event)
        }

        private func updateChromeVisibility(for event: NSEvent) {
            guard isEnabled, let window = configuredWindow else { return }
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
                ?? NSEvent.mouseLocation
            apply(isInRevealArea: isScreenPoint(point, inRevealAreaOf: window))
        }

        private func updateChromeVisibilityForCurrentPointer() {
            guard isEnabled, let window = configuredWindow else { return }
            apply(isInRevealArea: isScreenPoint(NSEvent.mouseLocation, inRevealAreaOf: window))
        }

        private func apply(isInRevealArea: Bool) {
            if isInRevealArea {
                cancelPendingHide()
                setWindowChromeHidden(false)
            } else {
                scheduleHide()
            }
        }

        private func scheduleHide() {
            // Only schedule once; a hide already in flight stands until it fires or
            // the pointer returning to the strip cancels it.
            guard !isChromeHidden, hideTask == nil else { return }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: StairsDistractionFree.hideDelay)
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                // Re-check: only hide if the pointer is still out of the strip.
                guard self.isEnabled, let window = self.configuredWindow,
                      !self.isScreenPoint(NSEvent.mouseLocation, inRevealAreaOf: window) else {
                    return
                }
                self.setWindowChromeHidden(true)
            }
        }

        private func cancelPendingHide() {
            hideTask?.cancel()
            hideTask = nil
        }

        private func isScreenPoint(_ point: NSPoint, inRevealAreaOf window: NSWindow) -> Bool {
            let frame = window.frame
            guard point.x >= frame.minX, point.x <= frame.maxX else { return false }
            // `NSRect.contains` excludes the max-Y edge — which is exactly the
            // toolbar strip — so a pointer resting on the toolbar would read as
            // outside the window and strobe. Test the top strip inclusively, and
            // hold the toolbar a little further down once shown (hysteresis).
            let distanceFromTop = frame.maxY - point.y
            guard distanceFromTop >= 0 else { return false }
            let limit = isChromeHidden
                ? StairsDistractionFree.revealHeight
                : StairsDistractionFree.revealHeight + StairsDistractionFree.revealHysteresis
            return distanceFromTop <= limit
        }

        private func setWindowChromeHidden(_ hidden: Bool) {
            guard isChromeHidden != hidden else { return }
            isChromeHidden = hidden
            // Hiding the toolbar leaves the bare titlebar strip, which draws the
            // standard material over the model; make it transparent only while the
            // chrome is hidden, so normal mode keeps the standard toolbar look.
            configuredWindow?.titlebarAppearsTransparent = hidden
            // The traffic lights are deliberately left alone: hiding them — even by
            // alpha rather than `isHidden` — makes ⌘W and ⌘M silently no-op, because
            // `performClose:`/`performMiniaturize:` work by simulating a click on
            // those buttons.
            onChromeHiddenChange(hidden)
        }

        private func restoreWindowChrome() {
            cancelPendingHide()
            guard isChromeHidden else { return }
            isChromeHidden = false
            configuredWindow?.titlebarAppearsTransparent = false
            onChromeHiddenChange(false)
        }
    }
}
#endif
