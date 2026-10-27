import AppKit
import SwiftUI

struct DictationPane: View {
    @AppStorage("pasteMode") private var pasteMode = Paster.Mode.paste.rawValue
    @AppStorage("removeFillers") private var removeFillers = true
    @AppStorage("customWords") private var customWords = ""
    @AppStorage("showWords") private var showWords = true
    @AppStorage(QuietOutput.key) private var muteWhileDictating = false
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        BrandPage("Dictation") {
            BrandSection("Shortcut") {
                BrandRow("Dictate", subtitle: "Hold to talk, or tap to start and stop") {
                    ShortcutRecorder(action: .dictate)
                }
                DictationShortcutWarning()
            }
            BrandSection("While you talk") {
                BrandRow("Show words as you talk", isOn: $showWords)
                BrandRow("Mute other sound", isOn: $muteWhileDictating)
            }
            BrandSection("Pasting", footer: "Your words stay on the clipboard. If they don’t appear in the app, press ⌘V to paste them.") {
                BrandRow("After dictating") {
                    Picker("After dictating", selection: Binding(get: { Paster.Mode(rawValue: pasteMode)?.rawValue ?? Paster.Mode.paste.rawValue }, set: { pasteMode = $0 })) {
                        Text("Copy and paste").tag(Paster.Mode.paste.rawValue)
                        Text("Copy only").tag(Paster.Mode.copy.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                if pasteMode != Paster.Mode.copy.rawValue {
                    if !trusted {
                        BrandRow("Pasting needs Accessibility", subtitle: "Until it's on, your words are copied instead.", subtitleColor: .coralText) {
                            Button("Turn On…") { Onboarding.shared.show(at: .accessibility) }.buttonStyle(.paper)
                        }
                    }
                }
            }
            BrandSection("Text cleanup") {
                BrandRow("Remove “um” and “uh”", isOn: $removeFillers)
            }
            BrandSection("Custom words", footer: "Add names and terms here to help spell them correctly. Only words you add here are included.") {
                VStack(alignment: .leading, spacing: 10) {
                    TokenField(text: $customWords, prompt: "Names and terms to spell right")
                        .onChange(of: customWords) { NotificationCenter.default.post(name: .yapSketchCustomWordsChanged, object: nil) }
                }
                .padding(16)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

}
