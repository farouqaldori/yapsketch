import AppKit
import Carbon

/// Puts text into the front app through the clipboard and ⌘V, then gives the clipboard back.
/// Posting ⌘V needs Accessibility.
enum Paster {
    /// Paste and restore the clipboard, paste and leave the text on it, or only copy.
    enum Mode: String, CaseIterable { case paste, pasteAndKeep, copy }

    static var mode: Mode { UserDefaults.standard.string(forKey: "pasteMode").flatMap(Mode.init) ?? .paste }
    /// Press Return after pasting.
    static var submit: Bool { UserDefaults.standard.bool(forKey: "pasteSubmit") }

    /// True when it was pasted; false when it was only copied (asked to, no Accessibility, or
    /// nothing to type into in front, where ⌘V would only make the app beep).
    @MainActor
    @discardableResult
    static func deliver(_ text: String, mode: Mode = Paster.mode, submit: Bool = Paster.submit) async -> Bool {
        let pb = NSPasteboard.general
        guard mode != .copy, AXIsProcessTrusted(), focusedTarget() != .none else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Marks it as transient, so clipboard managers skip it.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pb.changeCount
        try? await Task.sleep(nanoseconds: 60_000_000)
        press(key: vKey, flags: .maskCommand)
        if submit {
            try? await Task.sleep(nanoseconds: 120_000_000)
            press(key: CGKeyCode(kVK_Return), flags: [])
        }
        guard mode == .paste else { return true }
        // Long enough for the app to read it; then the old clipboard, unless something new
        // was copied meanwhile.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard pb.changeCount == ours else { return true }
        pb.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return true
    }

    private enum Target { case text, none, unknown }

    /// What has focus in the front app. Only `none` when that's certain: nothing focused, or
    /// something that clearly takes no typing. Anything unclear is pasted into as before.
    private static func focusedTarget() -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron apps describe their text fields only once asked to.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .noValue { return .none }
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

    private static func press(key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types "v" on this keyboard layout (⌘V follows the layout), else ANSI V.
    private static var vKey: CGKeyCode {
        for code in 0..<128 where Shortcut(keyCode: code, modifiers: 0).keyName == "V" { return CGKeyCode(code) }
        return CGKeyCode(kVK_ANSI_V)
    }
}
