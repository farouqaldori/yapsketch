import AppKit
import Carbon
import SwiftUI

struct GeneralPane: View {
    @AppStorage("soundPack") private var soundPack = Sounds.Pack.click.rawValue
    @State private var updatesByItself = Updates.shared.updatesByItself
    @State private var opensAtLogin = LoginItem.isOn

    var body: some View {
        BrandPage("General") {
            BrandSection("Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    BrandRow(
                        action.title,
                        subtitle: action == .draw
                            ? "Or hold ⌃⌥ and drag" : action == .dictate ? "Hold to talk, or tap to start and stop" : nil
                    ) {
                        ShortcutRecorder(action: action)
                    }
                    if action == .dictate { DictationShortcutWarning() }
                }
            }
            BrandSection("Microphone") {
                MicrophoneRow()
            }
            BrandSection("Startup") {
                BrandRow(
                    "Open at login",
                    subtitle: LoginItem.needsApproval ? "Approve YapSketch in System Settings › General › Login Items" : nil,
                    isOn: $opensAtLogin
                )
                .onChange(of: opensAtLogin) { LoginItem.set(opensAtLogin) }
            }
            BrandSection("Sounds") {
                BrandRow("Sound pack") {
                    Picker("Sound pack", selection: $soundPack) {
                        Text("Off").tag("off")
                        Divider()
                        ForEach(Sounds.Pack.allCases) { p in Text(p.name).tag(p.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: soundPack) { if let p = Sounds.Pack(rawValue: soundPack) { Sounds.preview(p) } }
                }
            }
            if Updates.isEnabled {
                BrandSection("Updates") {
                    BrandRow("Update by itself", isOn: $updatesByItself)
                        .onChange(of: updatesByItself) { Updates.shared.updatesByItself = updatesByItself }
                    BrandRow(Self.version) {
                        HStack(spacing: 14) {
                            if let notes = Updates.shared.currentNotes {
                                Button("What's new") { UpdateWindow.shared.show(installed: notes) }.buttonStyle(.link).font(.ui(13))
                            }
                            Button("Check now") { Updates.shared.checkForUpdates() }.buttonStyle(.paper)
                        }
                    }
                }
            } else {
                Text(Self.version).font(.ui(12)).foregroundStyle(.faint).padding(.leading, 2)
            }
        }
    }

    private static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "YapSketch \($0)" } ?? "YapSketch, development build"
    }
}

/// Which microphone dictation and recordings listen with.
private struct MicrophoneRow: View {
    @AppStorage(Microphone.key) private var chosen = ""
    @State private var devices = Microphone.all()
    @State private var systemDefault = Microphone.defaultName()
    @State private var watcher: AnyObject?

    var body: some View {
        BrandRow("Listen with", subtitle: missing.map { "Used for dictation and recordings. \($0) isn't connected, so it's the Mac's default for now." } ?? "Used for dictation and recordings") {
            Picker("Listen with", selection: $chosen) {
                Text(systemDefault.map { "Same as macOS (\($0))" } ?? "Same as macOS").tag("")
                Divider()
                ForEach(devices) { d in Text(d.name).tag(d.id) }
                if let missing { Text(missing).tag(chosen) }
            }
            .labelsHidden().fixedSize()
            .onChange(of: chosen) { refresh() }
        }
        .onAppear {
            refresh()
            watcher = Microphone.watch { DispatchQueue.main.async { refresh() } }
        }
        .onDisappear { watcher = nil }
    }

    /// The chosen microphone, by name, when it isn't connected.
    private var missing: String? {
        guard !chosen.isEmpty, !devices.contains(where: { $0.id == chosen }) else { return nil }
        return UserDefaults.standard.string(forKey: Microphone.key + "Name") ?? "The chosen microphone"
    }

    private func refresh() {
        devices = Microphone.all()
        systemDefault = Microphone.defaultName()
        if let d = devices.first(where: { $0.id == chosen }) { UserDefaults.standard.set(d.name, forKey: Microphone.key + "Name") }
    }
}
