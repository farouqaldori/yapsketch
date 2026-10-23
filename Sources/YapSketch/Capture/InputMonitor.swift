import AppKit
import ApplicationServices
import Carbon

/// Listens passively to clicks and keystrokes system-wide. Needs Accessibility and Input
/// Monitoring, and does nothing without them.
final class InputMonitor {
    struct Click {
        let t: Double
        let global: CGPoint
        let button: String
    }

    var clock: () -> Double = { 0 }
    var isSuppressed: () -> Bool = { false }
    var logKeystrokes = true

    /// Main queue.
    var onClick: ((Click) -> Void)?
    /// Scrolling, at most every 0.2 s.
    var onScroll: ((Double) -> Void)?
    private var lastScroll = -1.0
    /// Main queue. Typed text runs and shortcuts.
    var onKeys: ((Double, String) -> Void)?
    var onShortcut: ((Double, String) -> Void)?
    /// Main queue.
    var onKeycast: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var typed = ""
    private var typedStart: Double = 0
    private var flushWork: DispatchWorkItem?

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    if let refcon {
                        Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            )
        else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        flushTyped()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if isSuppressed() { return }
        let t = clock()

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            flushTyped()
            let p = event.location
            let button = type == .leftMouseDown ? "left" : type == .rightMouseDown ? "right" : "middle"
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            let label = clicks >= 2 ? "\(button) ×\(clicks)" : button
            onClick?(Click(t: t, global: p, button: label))
        case .scrollWheel:
            if t - lastScroll >= 0.2 {
                lastScroll = t
                onScroll?(t)
            }
        case .keyDown:
            handleKey(event, t: t)
        default:
            break
        }
    }

    private static let specialKeys: [Int64: String] = [
        36: "↩", 76: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 49: "␣",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private func handleKey(_ event: CGEvent, t: Double) {
        guard logKeystrokes else { return }
        if IsSecureEventInputEnabled() {
            // Password fields etc. Never record what's typed.
            if typed != "•••" {
                flushTyped()
                typedStart = t
                typed = "•••"
            }
            scheduleFlush()
            return
        }

        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        let hasCommand = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if hasCommand || (Self.specialKeys[code] != nil && code != 49 && code != 51 && code != 36 && code != 76) {
            var mods = ""
            if flags.contains(.maskControl) { mods += "⌃" }
            if flags.contains(.maskAlternate) { mods += "⌥" }
            if flags.contains(.maskShift) { mods += "⇧" }
            if flags.contains(.maskCommand) { mods += "⌘" }
            let key = Self.specialKeys[code] ?? chars.uppercased()
            let combo = mods + key
            flushTyped()
            DispatchQueue.main.async {
                self.onShortcut?(t, combo)
                self.onKeycast?(combo)
            }
            return
        }

        if typed.isEmpty { typedStart = t }
        switch code {
        case 51:
            if let last = typed.last, last != "⌫", last != "↩" { typed.removeLast() } else { typed += "⌫" }
        case 36, 76:
            typed += "↩"
        default:
            var s = NSEvent(cgEvent: event)?.characters ?? chars
            s = s.filter { $0.asciiValue.map { $0 >= 32 } ?? true }
            typed += s
        }
        let preview = String(typed.suffix(40))
        DispatchQueue.main.async { self.onKeycast?(preview) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushTyped() }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func flushTyped() {
        flushWork?.cancel()
        guard !typed.isEmpty else { return }
        let text = typed
        let t = typedStart
        typed = ""
        DispatchQueue.main.async { self.onKeys?(t, text) }
    }
}
