import SwiftUI
import AppKit

/// Shrink-wraps the MenuBarExtra panel to its SwiftUI content each time the
/// popout is shown. Works around a SwiftUI bug where the panel keeps its old,
/// larger frame after the content got smaller since the last open, leaving a
/// translucent empty margin hanging around the menu.
///
/// Attach as a `.background` *after* all sizing modifiers, so this view's own
/// frame is exactly the content's final footprint. Resizing the panel to that
/// footprint (in screen coordinates) removes the stale margin without moving
/// the visible menu, so no anchor math against the status item is needed.
struct MenuBarWindowResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizerView { ResizerView() }
    func updateNSView(_ nsView: ResizerView, context: Context) {}

    final class ResizerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            // Occlusion state changes on every show/hide of the popout — the
            // closest thing MenuBarExtra offers to an "opened" event.
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.fitWindowToContent()
            }
            // First open: the view lands in the window before it is on screen,
            // so the layout isn't final until the next runloop turn.
            DispatchQueue.main.async { [weak self] in
                self?.fitWindowToContent()
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func fitWindowToContent() {
            guard let window, window.isVisible else { return }
            let contentRect = window.convertToScreen(convert(bounds, to: nil))
            guard contentRect.width > 1, contentRect.height > 1 else { return }
            let frame = window.frame
            // In the healthy case the panel already matches the content; only
            // touch the frame when it's visibly off, to avoid resize feedback.
            let mismatch = max(
                abs(frame.width - contentRect.width),
                abs(frame.height - contentRect.height)
            )
            guard mismatch > 1 else { return }
            window.setFrame(contentRect, display: true)
            // The panel's rounded corners come from a private window-level
            // corner mask that some macOS versions do not rebuild after a
            // manual setFrame, leaving the popout square (#14). Ask the window
            // to re-derive it; skip silently where the selector doesn't exist.
            let refreshMask = NSSelectorFromString("_cornerMaskChanged")
            if window.responds(to: refreshMask) {
                window.perform(refreshMask)
            }
            window.invalidateShadow()
        }
    }
}
