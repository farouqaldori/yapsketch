import AppKit
import Carbon
import SwiftUI

struct GeneralPane: View {
    @AppStorage("copyWhenDone") private var copyWhenDone = true
    @AppStorage("pasteWhenDone") private var pasteWhenDone = false
    @State private var checksForUpdates = Updates.shared.automaticallyChecks
    @State private var opensAtLogin = LoginItem.isOn
    /// What macOS does with 🌐 too, when dictation is on fn.
    @State private var globeKey: String?

    var body: some View {
        BrandPage("General") {
            BrandSection("Shortcuts", footer: "Click a shortcut and press the new keys. Esc cancels.") {
                ForEach(ShortcutAction.allCases) { action in
                    BrandRow(
                        action.title,
                        subtitle: action == .draw
                            ? "Or hold ⌃⌥ and drag" : action == .dictate ? "Hold to talk, or tap to start and stop" : nil
                    ) {
                        ShortcutRecorder(action: action)
                    }
                    if action == .dictate, let globeKey {
                        BrandRow("fn also \(globeKey)", subtitle: "To stop that, set “Press 🌐 key to” to Do Nothing in Keyboard settings.", subtitleColor: .coralText) {
                            Button("Keyboard Settings…") { FnKey.openKeyboardSettings() }.buttonStyle(.paper)
                        }
                    }
                }
            }
            BrandSection("Startup") {
                BrandRow(
                    "Open at login",
                    subtitle: LoginItem.needsApproval ? "Approve YapSketch in System Settings › General › Login Items" : "YapSketch waits in the menu bar",
                    isOn: $opensAtLogin
                )
                .onChange(of: opensAtLogin) { LoginItem.set(opensAtLogin) }
            }
            BrandSection("When a recording is done") {
                BrandRow("Copy the instructions for your agent", isOn: $copyWhenDone)
                BrandRow("Paste them into the app in front", subtitle: "Works when your agent's prompt box is active.", isOn: $pasteWhenDone)
            }
            if Updates.isEnabled {
                BrandSection("Updates") {
                    BrandRow("Check for updates automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { Updates.shared.automaticallyChecks = checksForUpdates }
                }
            }
            Text(Self.version).font(.ui(12)).foregroundStyle(.faint).padding(.leading, 2)
        }
        .onAppear(perform: refreshGlobeKey)
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchShortcutsChanged)) { _ in refreshGlobeKey() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshGlobeKey() }
    }

    private static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "YapSketch \($0)" } ?? "YapSketch, development build"
    }

    private func refreshGlobeKey() {
        globeKey = Shortcuts.get(.dictate).isFn ? FnKey.systemAction() : nil
    }
}
