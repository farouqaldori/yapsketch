import AppKit
import ApplicationServices

/// Tracks the frontmost app, its focused window title and (when exposed) the
/// document URL or file path, e.g. the page open in Safari or the file in Xcode.
final class AppTracker {
    struct Context: Equatable {
        var app: String
        var window: String?
        var url: String?
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
            // Chrome, Electron and other Chromium apps only expose page elements (links,
            // buttons, DOM ids) once an assistive app asks for them.
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
            }
        }

        guard ctx != current else { return }
        let appChanged = ctx.app != current?.app
        current = ctx
        onChange?(ctx, appChanged)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
}
