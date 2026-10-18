import AppKit
import SwiftUI

/// An update's notes with Later and Update and reopen, then its progress in the same place.
/// Also what's new in the version running now, after an update.
@MainActor
final class UpdateWindow {
    static let shared = UpdateWindow()
    private var window: NSWindow?

    /// `installed`: the notes of the version running now, rather than the waiting update.
    func show(installed: Updates.Release? = nil) {
        Brand.registerFonts()
        let view = UpdateView(updates: .shared, installed: installed) { [weak self] in self?.close() }
        if let window {
            window.contentViewController = NSHostingController(rootView: view.focusEffectDisabled())
        } else {
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 450),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "YapSketch Update"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .aqua)
            w.backgroundColor = Brand.paper
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: view.focusEffectDisabled())
            w.setContentSize(CGSize(width: 600, height: 450))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

private struct UpdateView: View {
    @ObservedObject var updates: Updates
    let installed: Updates.Release?
    let close: () -> Void
    @State private var byItself = Updates.shared.updatesByItself

    private var release: Updates.Release? { installed ?? updates.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AppMark(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(installed != nil ? "What's new in YapSketch \(release?.version ?? "")" : "YapSketch \(release?.version ?? "") is ready")
                        .font(.serif(28)).kerning(-0.5).foregroundStyle(.ink).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.ui(13.5)).foregroundStyle(.soft)
                }
            }
            notes.padding(.top, 22)
            footer.frame(height: 44).padding(.top, 20)
        }
        .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 28)
        .frame(width: 600, height: 450)
        .background(.paper)
    }

    private var subtitle: String {
        let released = release?.date.map { "Released \($0.formatted(.dateTime.day().month(.wide)))." } ?? ""
        if installed != nil { return released.isEmpty ? "Installed and ready." : released }
        return ["You have \(Updates.currentVersion).", released].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT'S NEW").font(.mono(11, .medium)).kerning(1.6).foregroundStyle(.soft)
                if let points = release?.notes, !points.isEmpty {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Circle().fill(.coral).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(point).font(.ui(14.5)).foregroundStyle(.ink).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Fixes and small improvements.").font(.ui(14.5)).foregroundStyle(.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.line, lineWidth: 1.5))
    }

    @ViewBuilder private var footer: some View {
        if installed != nil {
            HStack {
                Spacer()
                Button("Close", action: close).buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        } else {
            switch updates.phase {
            case .waiting:
                HStack(spacing: 12) {
                    Toggle(isOn: $byItself) { Text("Update by itself from now on").font(.ui(13)).foregroundStyle(.inkSoft) }
                        .toggleStyle(.checkbox)
                        .focusable(false)
                        .onChange(of: byItself) { updates.updatesByItself = byItself }
                    Spacer()
                    Button("Later", action: close).buttonStyle(.paperLarge).keyboardShortcut(.cancelAction)
                    Button("Update and reopen") { updates.install() }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                }
            case .downloading(let progress):
                progressRow("Downloading the update", progress, cancel: true)
            case .preparing:
                progressRow("Getting it ready", nil, cancel: false)
            case .installing:
                progressRow("Reopening YapSketch", nil, cancel: false)
            }
        }
    }

    private func progressRow(_ label: String, _ progress: Double?, cancel: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label).font(.ui(13.5)).foregroundStyle(.ink)
                    Spacer()
                    if let progress { Text("\(Int(progress * 100))%").font(.mono(12.5, .medium)).foregroundStyle(.soft) }
                }
                ProgressLine(value: progress)
            }
            if cancel { Button("Cancel") { updates.cancel() }.buttonStyle(.paperLarge) }
        }
    }
}

/// Coral on a pale track; without a value, a short run sweeping across.
private struct ProgressLine: View {
    let value: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.rule)
                if let value {
                    Capsule().fill(.coral).frame(width: max(6, g.size.width * value))
                } else {
                    Capsule().fill(.coral).frame(width: g.size.width * 0.3)
                        .offset(x: sweep ? g.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}
