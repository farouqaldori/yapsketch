import AppKit
import SwiftUI

/// Shared by the shortcut overview and Dictation settings.
struct DictationShortcutWarning: View {
    @State private var globeKey: String?

    var body: some View {
        Group {
            if let globeKey {
                BrandRow("fn also \(globeKey)", subtitle: "To stop that, set “Press 🌐 key to” to Do Nothing in Keyboard settings.", subtitleColor: .coralText) {
                    Button("Keyboard Settings…") { FnKey.openKeyboardSettings() }.buttonStyle(.paper)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchShortcutsChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        globeKey = Shortcuts.get(.dictate).isFn ? FnKey.systemAction() : nil
    }
}
