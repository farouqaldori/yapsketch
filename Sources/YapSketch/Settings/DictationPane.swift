import AppKit
import SwiftUI

struct DictationPane: View {
    @AppStorage("pasteMode") private var pasteMode = Paster.Mode.paste.rawValue
    @AppStorage("pasteSubmit") private var submit = false
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("customWords") private var customWords = ""
    @AppStorage("showWords") private var showWords = true
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        BrandPage("Dictation") {
            BrandSection("Shortcut") {
                BrandRow("Dictate", subtitle: "Hold to talk, or tap to start and stop") {
                    ShortcutRecorder(action: .dictate)
                }
            }
            BrandSection("Pasting") {
                BrandRow("After dictating") {
                    Picker("After dictating", selection: $pasteMode) {
                        Text("Paste").tag(Paster.Mode.paste.rawValue)
                        Text("Paste and keep copied").tag(Paster.Mode.pasteAndKeep.rawValue)
                        Text("Copy only").tag(Paster.Mode.copy.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                if pasteMode != Paster.Mode.copy.rawValue {
                    BrandRow("Press Return after pasting", isOn: $submit)
                    if !trusted {
                        BrandRow("Pasting needs Accessibility", subtitle: "Until it's on, your words are copied instead.", subtitleColor: .coralText) {
                            Button("Turn On…") { Onboarding.shared.show(at: .accessibility) }.buttonStyle(.paper)
                        }
                    }
                }
            }
            BrandSection("Words") {
                BrandRow("Show words as you talk", isOn: $showWords)
                BrandRow("Remove “um” and “uh”", isOn: $removeFillers)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom words").font(.ui(14)).foregroundStyle(.ink)
                    TokenField(text: $customWords, prompt: "Names and terms to spell right")
                }
                .padding(16)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }
}
