import AppKit
import SwiftUI

/// Each permission, whether it's on, and a way to turn it on (the welcome's step for it).
struct PermissionsPane: View {
    @State private var granted: Set<Permission> = []

    var body: some View {
        BrandPage("Permissions") {
            BrandSection(footer: "Change them any time in System Settings › Privacy & Security.") {
                ForEach(Permission.allCases) { p in
                    BrandRow(p.title, subtitle: p.purpose) {
                        if granted.contains(p) {
                            Label("On", systemImage: "checkmark.circle.fill")
                                .font(.ui(13, .medium)).foregroundStyle(.doneText)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Button("Turn On…") { Onboarding.shared.show(at: p) }.buttonStyle(.ink)
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { granted = Set(Permission.allCases.filter(\.isGranted)) }
}
