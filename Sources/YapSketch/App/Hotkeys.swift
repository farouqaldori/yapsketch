import Carbon
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class Hotkeys {
    struct Combo {
        let keyCode: Int
        let modifiers: Int
        let display: String
    }

    private var handlers: [UInt32: () -> Void] = [:]
    /// For hold-to-talk: called when the keys are let go.
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refsByID: [UInt32: EventHotKeyRef] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return noErr }
                var hk = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                let me = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { (released ? me.releaseHandlers[hk.id] : me.handlers[hk.id])?() }
                return noErr
            }, 2, &specs, refcon, &eventHandler)
    }

    /// Returns the hotkey's id, or nil when the keys can't be had (another app holds them).
    @discardableResult
    func register(_ combo: Combo, released: (() -> Void)? = nil, _ handler: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5941_5053), id: id)  // 'YAPS'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            refsByID[id] = ref
            handlers[id] = handler
            releaseHandlers[id] = released
            return id
        }
        NSLog("YapSketch: couldn't register hotkey \(combo.display) (\(status))")
        return nil
    }

    @discardableResult
    func register(_ shortcut: Shortcut, released: (() -> Void)? = nil, _ handler: @escaping () -> Void) -> UInt32? {
        register(Combo(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, display: shortcut.display), released: released, handler)
    }

    func unregister(_ id: UInt32) {
        guard let ref = refsByID.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        refs.removeAll { $0 == ref }
        handlers[id] = nil
        releaseHandlers[id] = nil
    }

    /// Drops every hotkey (before registering the changed ones).
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        refsByID.removeAll()
        handlers.removeAll()
        releaseHandlers.removeAll()
    }
}
