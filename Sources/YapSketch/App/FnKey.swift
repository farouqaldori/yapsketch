import AppKit
import Carbon

/// Holding fn (🌐) on its own, which Carbon hotkeys can't register: a listen-only event tap
/// on modifier changes and key presses (Input Monitoring). fn with another key (fn+←, fn+F5,
/// ⌃fn…) is left alone, so those keep working.
final class FnKey {
    /// Called as a hotkey's press and release would be (main queue).
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key came while fn was held, after the press was passed on.
    var onCombo: (() -> Void)?

    /// fn is passed on once held this long, or let go sooner, with no other key: long enough to
    /// see fn+← coming, short enough not to lose the first word.
    private static let settle = 0.2

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var down = false
    /// This press went with another key: nothing more until fn is let go.
    private var combo = false
    private var passedOn = false
    private var pending: DispatchWorkItem?

    var isRunning: Bool { tap != nil }

    /// False without Input Monitoring; tries again every few seconds until it's granted.
    /// Without it, no tap is even tried: trying raises macOS's own "receive keystrokes"
    /// alert, ahead of the welcome's page for it.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard CGPreflightListenEventAccess(),
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    if let refcon {
                        Unmanaged<FnKey>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            )
        else {
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    if self?.start() == true { NotificationCenter.default.post(name: .yapSketchShortcutsChanged, object: nil) }
                }
            }
            return false
        }
        retry?.invalidate()
        retry = nil
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        pending?.cancel()
        pending = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        down = false
        combo = false
        passedOn = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if down { withAnotherKey() }
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            // 63 is fn; some keyboards send their 🌐 key as 179.
            guard code == kVK_Function || code == 179 else {
                if down, !event.flags.intersection(others).isEmpty { withAnotherKey() }
                return
            }
            let isDown = event.flags.contains(.maskSecondaryFn)
            guard isDown != down else { return }
            down = isDown
            if isDown {
                passedOn = false
                combo = !event.flags.intersection(others).isEmpty
                guard !combo else { return }
                let w = DispatchWorkItem { [weak self] in self?.passOn() }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: w)
            } else {
                pending?.cancel()
                pending = nil
                guard !combo else { return }
                // A quick tap: the press goes now, then the release.
                if !passedOn { passOn() }
                onRelease?()
            }
        default:
            break
        }
    }

    private func passOn() {
        pending = nil
        guard !passedOn, !combo else { return }
        passedOn = true
        onPress?()
    }

    private func withAnotherKey() {
        guard !combo else { return }
        combo = true
        pending?.cancel()
        pending = nil
        if passedOn { onCombo?() }
    }
}

extension FnKey {
    /// What macOS itself does when 🌐 is pressed ("Press 🌐 key to" in Keyboard settings), or
    /// nil for Do Nothing. Read, never changed.
    static func systemAction() -> String? {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int
        switch value {
        case 0: return nil
        case 1: return "switches the input source"
        case 2: return "opens Emoji & Symbols"
        case 3: return "starts macOS dictation"
        default: return "opens Emoji & Symbols or switches the input source"
        }
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
