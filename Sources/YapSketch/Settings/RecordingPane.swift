import AppKit
import SwiftUI

struct RecordingPane: View {
    /// A shorter period that would delete recordings now asks first.
    private func choose(_ days: Int) {
        let count = Storage.older(than: days).count
        if count == 0 { keepDays = days } else { confirm = (days, count) }
    }

    private func measure() async {
        let bytes = await Task.detached(priority: .utility) { Storage.usedBytes() }.value
        used = bytes == 0 ? "No recordings yet" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " used"
    }

    @AppStorage("recordWindow") private var recordWindow = false
    @AppStorage("systemAudio") private var systemAudio = false
    @AppStorage("logKeystrokes") private var logKeystrokes = true
    @AppStorage("temporaryInk") private var temporaryInk = true
    @AppStorage("inkSize") private var inkSize = 0.7
    @AppStorage("keepDays") private var keepDays = 0
    @State private var used: String?
    @State private var confirm: (days: Int, count: Int)?

    var body: some View {
        BrandPage("Recording") {
            BrandSection("Capture") {
                BrandRow("Record only the front window", isOn: $recordWindow)
                BrandRow("Record system audio", isOn: $systemAudio)
                BrandRow("Note the keys you type", subtitle: "Never in password fields", isOn: $logKeystrokes)
            }
            BrandSection("Ink") {
                BrandRow("Fade after a few seconds", isOn: $temporaryInk)
                BrandRow("Size") {
                    BrandSegmented(selection: $inkSize, options: [(0.7, "Thin"), (1.0, "Medium"), (1.5, "Bold")])
                        .frame(width: 240)
                        .accessibilityLabel("Ink size")
                }
            }
            BrandSection("Storage") {
                BrandRow("Keep recordings", subtitle: used ?? " ") {
                    Picker("Keep recordings", selection: Binding(get: { keepDays }, set: choose)) {
                        Text("Forever").tag(0)
                        Text("30 days").tag(30)
                        Text("7 days").tag(7)
                        Text("1 day").tag(1)
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .task { await measure() }
        .confirmationDialog(
            confirm.map { "Delete \($0.count) recording\($0.count == 1 ? "" : "s") older than \($0.days) day\($0.days == 1 ? "" : "s")?" }
                ?? "",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let c = confirm {
                    keepDays = c.days
                    Storage.cleanUp()
                }
                confirm = nil
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await measure()
                }
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text("From now on, recordings are deleted as they get older than that.")
        }
    }
}
