import AppKit
import SwiftUI

struct DictationPane: View {
    @AppStorage("pasteMode") private var pasteMode = Paster.Mode.paste.rawValue
    @AppStorage("pasteSubmit") private var submit = false
    @AppStorage("dictationCleanup") private var cleanup = "off"
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("customWords") private var customWords = ""
    @AppStorage("sounds") private var sounds = true
    @AppStorage("showWords") private var showWords = true
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        let accounts = Providers.connected.filter { $0.chat != nil }
        BrandPage("Dictation") {
            BrandSection(footer: "Press Esc to cancel a dictation. Nothing is pasted.") {
                BrandRow("Shortcut", subtitle: "Hold to talk, or tap to start and stop") {
                    ShortcutRecorder(action: .dictate)
                }
                BrandRow(
                    "After dictating",
                    subtitle: pasteMode == Paster.Mode.paste.rawValue ? "Paste leaves your clipboard as it was." : nil
                ) {
                    Picker("After dictating", selection: $pasteMode) {
                        Text("Paste").tag(Paster.Mode.paste.rawValue)
                        Text("Paste and keep copied").tag(Paster.Mode.pasteAndKeep.rawValue)
                        Text("Copy only").tag(Paster.Mode.copy.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                if pasteMode != Paster.Mode.copy.rawValue {
                    BrandRow("Press Return after pasting", subtitle: "Sends the message right away.", isOn: $submit)
                    if !trusted {
                        BrandRow("Pasting needs Accessibility", subtitle: "Until it's on, your words are copied instead.", subtitleColor: .coralText) {
                            Button("Turn On…") { Onboarding.shared.show(at: .accessibility) }.buttonStyle(.paper)
                        }
                    }
                }
            }
            BrandSection(footer: "Fixes punctuation and false starts without changing your words. Your text is sent to the provider you choose.") {
                BrandRow("Tidy up with AI", subtitle: tidySubtitle(accounts)) {
                    Picker("Tidy up with AI", selection: $cleanup) {
                        Text("Off").tag("off")
                        ForEach(accounts, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(accounts.isEmpty)
                }
            }
            BrandSection("Words", footer: "Also used for screen recordings.") {
                BrandRow("Remove “um” and “uh”", isOn: $removeFillers)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom words").font(.ui(14)).foregroundStyle(.ink)
                        Text("Names and terms YapSketch should spell right. Press Return or type a comma to add one.").font(.ui(12.5)).foregroundStyle(.soft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TokenField(text: $customWords, prompt: "Add a word")
                }
                .padding(16)
            }
            BrandSection {
                BrandRow("Show words as you talk", subtitle: "While dictating and in the recording toolbar", isOn: $showWords)
                BrandRow("Sounds", subtitle: "When the microphone starts and stops, for dictation and recordings", isOn: $sounds)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func tidySubtitle(_ accounts: [any Provider]) -> String {
        if let p = accounts.first(where: { $0.id == cleanup }), let chat = p.chat { return "\(chat.modelName) via \(p.name)" }
        if let chat = accounts.first?.chat {
            return "Off. Uses \(chat.modelName) through \(accounts.map(\.name).formatted(.list(type: .or)))."
        }
        return "Connect \(Providers.all.filter { $0.chat != nil }.map(\.name).formatted(.list(type: .or))) to use this"
    }
}
