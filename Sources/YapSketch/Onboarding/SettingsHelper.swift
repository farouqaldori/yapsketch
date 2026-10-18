import AppKit
import SwiftUI

/// The small card that sits beside System Settings while it's open at a permission's list:
/// YapSketch to drag in, and what to do then. It follows the window, steps aside while
/// another app is in front, and closes once the switch is on (Onboarding hides it).
@MainActor
final class SettingsHelper {
    private var panel: NSPanel?
    private var timer: Timer?
    private static let width: CGFloat = 250

    func show(permission: Permission, index: Int, of count: Int) {
        let card = HelperCard(label: "YapSketch setup · \(index) of \(count)")
        let host = NSHostingView(rootView: card)
        host.frame.size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host
        p.setContentSize(host.fittingSize)
        panel = p
        follow()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.appearance = NSAppearance(named: .aqua)
        return p
    }

    /// Beside System Settings' window (right if there's room, else left), shown only while it
    /// or YapSketch is in front.
    private func follow() {
        guard let panel else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == "com.apple.systempreferences" || front == Bundle.main.bundleIdentifier || front == nil,
            let settings = Self.settingsWindowFrame()
        else {
            panel.orderOut(nil)
            return
        }
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? settings
        var x = settings.maxX + 16
        if x + size.width > screen.maxX { x = settings.minX - 16 - size.width }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = min(max(settings.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    /// System Settings' main window, in screen coordinates (its bounds are readable without
    /// Screen Recording; only titles aren't). The largest of its windows: a password sheet in
    /// front of it is a window of its own, and the card stays with the main one.
    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
            let primary = NSScreen.screens.first
        else { return nil }
        let frames = list.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                let dict = info[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        guard let bounds = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // Quartz's top-left origin -> Cocoa's bottom-left.
        return CGRect(x: bounds.minX, y: primary.frame.height - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

/// "Drag me into the list.", the app to drag, then switch it on.
struct HelperCard: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(label)
            Text("Drag me into the list.").font(.serif(20)).kerning(-0.3).foregroundStyle(.ink)
            AppCard(compact: true)
            Text("Then turn it on. This card closes by itself when you're done.")
                .font(.ui(12.5)).foregroundStyle(.soft).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.paper))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}
