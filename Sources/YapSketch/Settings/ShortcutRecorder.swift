import AppKit
import Carbon
import SwiftUI

/// Click, then press the new keys: saved at once (esc cancels). Needs ⌃, ⌥ or ⌘, or fn on
/// its own for Dictate; a shortcut another action has, or another app holds, is pointed out.
/// As keycaps in a Settings row, or (given a `card` title) as a card on the welcome's last page.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    var card: String?
    @State private var current: Shortcut
    @State private var listening = false
    @State private var monitor: Any?
    @State private var message: String?
    /// fn is down with nothing else yet: let go, it's the shortcut.
    @State private var fnAlone = false

    init(action: ShortcutAction, card: String? = nil) {
        self.action = action
        self.card = card
        _current = State(initialValue: Shortcuts.get(action))
    }

    var body: some View {
        Group {
            if card != nil { cardBody } else { rowBody }
        }
        .onAppear(perform: checkAvailable)
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchShortcutsChanged)) { _ in current = Shortcuts.get(action) }
    }

    private var rowBody: some View {
        HStack(spacing: 8) {
            if let message { Text(message).font(.ui(12.5)).foregroundStyle(.coralText) }
            Button(action: { listening ? stop() : start() }) {
                Group {
                    if listening { waiting } else { Keycaps(current) }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(listening ? "Press the new shortcut (esc cancels)" : "Change")
            .accessibilityLabel("\(action.title): \(current.display)")
            .accessibilityHint(listening ? "Waiting for a new shortcut. Press Escape to cancel." : "Click to change")
            if current != action.standard, !listening {
                Button {
                    save(nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(.soft)
                }
                .buttonStyle(.borderless).help("Back to \(action.standard.display)")
            }
        }
    }

    /// Keys over the action's name, "Change" under it; coral while waiting for new keys.
    private var cardBody: some View {
        Button(action: { listening ? stop() : start() }) {
            VStack(spacing: 10) {
                Group {
                    if listening { waiting } else { Keycaps(current, large: true) }
                }
                .frame(height: 34)
                Text(card ?? "").font(.ui(13.5, .medium)).foregroundStyle(.ink)
                Text(message ?? (listening ? "Esc to cancel · was \(current.display)" : "Change"))
                    .font(.ui(12)).foregroundStyle(message == nil ? .soft : .coralText)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18).padding(.bottom, 14).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(listening ? .coralWash : .card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(listening ? .coral : .line, lineWidth: listening ? 1.5 : 1))
            .background(RoundedRectangle(cornerRadius: 14).stroke(Color.coral.opacity(listening ? 0.12 : 0), lineWidth: 8))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card ?? action.title), \(current.display)")
        .accessibilityHint(listening ? "Waiting for a new shortcut. Press Escape to cancel." : "Click to change")
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            Circle().fill(.coral).frame(width: 7, height: 7)
            Text("Press a new shortcut").font(.ui(12.5)).foregroundStyle(.coralText)
        }
        .padding(.horizontal, 12)
        .frame(height: card == nil ? 26 : 34)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.coral, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
    }

    private func start() {
        message = nil
        listening = true
        fnAlone = false
        Shortcuts.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            if e.type == .flagsChanged {
                fnChanged(e)
                return nil
            }
            fnAlone = false
            if e.keyCode == 53 {
                stop()
                return nil
            }
            guard let s = Shortcut(event: e) else {
                message = action == .dictate ? "Add ⌃, ⌥ or ⌘, use an F-key, or press fn alone" : "Add ⌃, ⌥ or ⌘, or use an F-key"
                NSSound.beep()
                return nil
            }
            if let other = Shortcuts.clash(s, besides: action) {
                message = "Already used for \(other.title.lowercased())"
                NSSound.beep()
                return nil
            }
            save(s)
            stop()
            return nil
        }
    }

    /// fn pressed and let go with no other key.
    private func fnChanged(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFn = e.keyCode == UInt16(kVK_Function) || e.keyCode == 179
        if isFn, f.contains(.function) {
            fnAlone = f.isDisjoint(with: [.control, .option, .shift, .command])
        } else if isFn, fnAlone {
            fnAlone = false
            guard action == .dictate else {
                message = "fn alone works only for Dictate"
                NSSound.beep()
                return
            }
            save(.fn)
            stop()
        } else {
            fnAlone = false
        }
    }

    private func checkAvailable() {
        guard Shortcuts.unavailable.contains(action) else { return }
        message = current.isFn ? "Needs Input Monitoring" : "Another app already uses this shortcut"
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard listening else { return }
        listening = false
        Shortcuts.suspend(false)
        // Registered again: say so if another app has these keys.
        DispatchQueue.main.async { checkAvailable() }
    }

    private func save(_ s: Shortcut?) {
        Shortcuts.set(action, s)
        current = Shortcuts.get(action)
        message = nil
        DispatchQueue.main.async { checkAvailable() }
    }
}
