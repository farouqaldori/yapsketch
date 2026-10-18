import AppKit

/// A tooltip for the toolbar and the status pill. macOS shows tooltips only in the active
/// app's windows, and those panels never take focus from the app being recorded, so they
/// draw their own.
final class HoverTip {
    static let shared = HoverTip()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var work: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// A tip is showing (or was a moment ago): the next one moves there at once.
    private var warm = false

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Brand.chrome.withAlphaComponent(0.96).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.black.cgColor
        label.font = Brand.ui(11.5, .medium)
        label.textColor = .white
        box.addSubview(label)
        panel.contentView = box
    }

    /// Shows `text` above `view` after a short hover, or at once if a tip is already showing.
    func schedule(_ text: String?, for view: NSView) {
        work?.cancel()
        hideWork?.cancel()
        guard let text, !text.isEmpty else {
            hide()
            return
        }
        if warm {
            show(text, above: view)
            return
        }
        let w = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view else { return }
            self.show(text, above: view)
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    /// Hides the tip after a moment, long enough to reach the next control.
    func leave() {
        work?.cancel()
        hideWork?.cancel()
        let h = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = h
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: h)
    }

    func hide() {
        work?.cancel()
        hideWork?.cancel()
        warm = false
        panel.orderOut(nil)
    }

    private func show(_ text: String, above view: NSView) {
        guard let window = view.window, window.isVisible else { return }
        label.stringValue = text
        let size = label.intrinsicContentSize
        let w = ceil(size.width) + 18
        let h = ceil(size.height) + 10
        label.frame = CGRect(x: 9, y: (h - size.height) / 2, width: ceil(size.width) + 2, height: size.height)
        let r = window.convertToScreen(view.convert(view.bounds, to: nil))
        var x = r.midX - w / 2
        if let screen = window.screen?.visibleFrame { x = min(max(x, screen.minX + 6), screen.maxX - w - 6) }
        panel.setFrame(CGRect(x: x, y: window.frame.maxY + 6, width: w, height: h), display: true)
        panel.orderFrontRegardless()
        warm = true
    }
}
