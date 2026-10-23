import AppKit
import ApplicationServices

final class AppTracker {
    struct Context: Equatable {
        var app: String
        var window: String?
        var url: String?
        /// The window's frame in global coordinates (top-left origin). Moving or resizing a
        /// window doesn't make it a new context.
        var frame: CGRect?

        static func == (a: Context, b: Context) -> Bool { a.app == b.app && a.window == b.window && a.url == b.url }
    }

    /// Main queue. `appChanged` is false when only the window/document changed.
    var onChange: ((Context, _ appChanged: Bool) -> Void)?
    private(set) var current: Context?
    private var timer: Timer?
    private var enabledPID: pid_t = 0

    func start() {
        current = nil
        poll()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Our own overlay grabs focus in draw mode; that's not a real app switch.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        var ctx = Context(app: app.localizedName ?? app.bundleIdentifier ?? "Unknown")
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            // Chrome, Electron and other Chromium apps only fill in their accessibility (the
            // window's page) once an assistive app asks for it.
            if app.processIdentifier != enabledPID {
                AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                enabledPID = app.processIdentifier
            }
            var win: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
                let win, CFGetTypeID(win) == AXUIElementGetTypeID()
            {
                let w = win as! AXUIElement
                ctx.window = Self.string(w, kAXTitleAttribute)
                ctx.url = Self.string(w, kAXDocumentAttribute)
                ctx.frame = Self.frame(w)
            }
        }

        guard ctx != current else { return }
        let appChanged = ctx.app != current?.app
        current = ctx
        onChange?(ctx, appChanged)
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
            let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            AXValueGetValue(pos as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
}
