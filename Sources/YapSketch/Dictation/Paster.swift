import AppKit
import Carbon

/// Copies text and optionally sends ⌘V. The text stays copied for manual paste or reuse.
enum Paster {
    enum Mode: String, CaseIterable { case paste, copy }

    // The old "pasteAndKeep" choice has the same behavior as paste now.
    static var mode: Mode { UserDefaults.standard.string(forKey: "pasteMode").flatMap(Mode.init) ?? .paste }

    /// Sending ⌘V is a best-effort request, not confirmation that the app inserted text.
    @MainActor
    static func deliver(_ text: String, mode: Mode = Paster.mode) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return }
        guard mode == .paste, AXIsProcessTrusted(), focusedTarget() != .none else { return }
        pressPaste()
    }

    private enum Target { case text, none, unknown }

    /// What has focus in the front app. Only `none` when that's certain: something that clearly
    /// takes no typing. Anything unclear is pasted into as before.
    private static func focusedTarget() -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // An app that's busy answers late or never: not worth holding up the paste for.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        // Chromium and Electron apps describe their text fields only once asked to.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        // Chrome says nothing has focus even with the cursor in a page's text box, so "nothing"
        // is unclear too.
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        let element = focused as! AXUIElement
        var settable: DarwinBoolean = false
        for attribute in [kAXSelectedTextRangeAttribute, kAXValueAttribute] {
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue { return .text }
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        switch role as? String {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return .text
        case "AXWindow", "AXApplication", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXBrowser", "AXButton",
            "AXImage", "AXStaticText", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXToolbar":
            return .none
        default: return .unknown
        }
    }

    /// ⌘ goes down and up around V like a real keystroke: some apps look at the keys held,
    /// not only the flags on the V.
    private static func pressPaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let command = CGKeyCode(kVK_Command)
        let events = [
            CGEvent(keyboardEventSource: src, virtualKey: command, keyDown: true),
            CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
            CGEvent(keyboardEventSource: src, virtualKey: command, keyDown: false),
        ]
        for (i, e) in events.enumerated() {
            e?.flags = i == 3 ? [] : .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    /// The key that types "v" on this keyboard layout (⌘V follows the layout), else ANSI V.
    private static var vKey: CGKeyCode {
        for code in 0..<128 where Shortcut(keyCode: code, modifiers: 0).keyName == "V" { return CGKeyCode(code) }
        return CGKeyCode(kVK_ANSI_V)
    }
}
