import AppKit
import SwiftUI

/// The Settings window: General, Recording, Dictation, Models and History, in a sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case recording = "Recording"
    case dictation = "Dictation"
    case models = "Models"
    case permissions = "Permissions"
    case history = "History"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .dictation: return "mic"
        case .models: return "cube"
        case .permissions: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class SettingsWindow: ObservableObject {
    static let shared = SettingsWindow()
    @Published var pane: SettingsPane? = .general
    private var window: NSWindow?

    func show(_ pane: SettingsPane? = nil) {
        if let pane { self.pane = pane }
        if window == nil {
            // Roomy by default (History shows pictures), never more than the screen allows.
            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            let size = CGSize(width: min(1120, screen.width - 80), height: min(780, screen.height - 60))
            let w = makeWindow(size: size)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window: paper, edge to edge, the traffic lights over the sidebar. Always light,
    /// like the brand; the controls in it stay the system's.
    func makeWindow(size: CGSize) -> NSWindow {
        Brand.registerFonts()
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "YapSketch Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .aqua)
        w.backgroundColor = Brand.paper
        w.isReleasedWhenClosed = false
        w.minSize = CGSize(width: 760, height: 520)
        let host = NSHostingController(rootView: SettingsView(nav: self).focusEffectDisabled())
        // The window is the size you make it: a long dictation or title mustn't widen it
        // (it did, and the window jumped as you moved through History).
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(size)
        return w
    }
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsWindow

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: Binding(get: { nav.pane ?? .general }, set: { nav.pane = $0 }))
            Group {
                switch nav.pane ?? .general {
                case .general: GeneralPane()
                case .recording: RecordingPane()
                case .dictation: DictationPane()
                case .models: ModelsPane()
                case .permissions: PermissionsPane()
                case .history: HistoryPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.paper)
        .ignoresSafeArea()
        .tint(.ink)
    }
}

/// The pages, the first on the header line beside the page title. ↑ and ↓ move between them.
private struct Sidebar: View {
    @Binding var selection: SettingsPane
    @FocusState private var focused: Bool
    /// A coral dot on Permissions while one is off.
    @State private var permissionsMissing = !Permission.allGranted
    /// And on Models while an account is out of funds or needs reconnecting.
    @State private var accountTrouble = Sidebar.anyAccountTrouble
    private static var anyAccountTrouble: Bool { Providers.connected.contains { Credentials.problem(for: $0.id) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in item(pane) }
            Spacer()
            star
        }
        .padding(.horizontal, 12).padding(.top, Brand.headerTop + (Brand.headerHeight - 36) / 2)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.panel)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionsMissing = !Permission.allGranted
            accountTrouble = Self.anyAccountTrouble
        }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchAccountsChanged)) { _ in
            accountTrouble = Self.anyAccountTrouble
        }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
    }

    /// At the foot of the sidebar, quieter than the pages.
    private var star: some View {
        Button(action: Links.starOnGitHub) {
            HStack(spacing: 10) {
                Image(nsImage: Links.gitHubMark).renderingMode(.template).frame(width: 18)
                Text("Star on GitHub").font(.ui(13))
                Spacer()
            }
            .foregroundStyle(.soft)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
        .help("github.com/farouqaldori/yapsketch")
    }

    private func item(_ pane: SettingsPane) -> some View {
        let on = pane == selection
        return Button {
            selection = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.icon).font(.system(size: 13.5)).foregroundStyle(on ? .coral : .soft).frame(width: 18)
                Text(pane.rawValue).font(.ui(13.5, on ? .medium : .regular)).foregroundStyle(on ? .ink : .inkSoft)
                Spacer()
                if (pane == .permissions && permissionsMissing) || (pane == .models && accountTrouble) {
                    Circle().fill(.coral).frame(width: 7, height: 7).accessibilityLabel("Needs attention")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(on ? .card : .clear)
                    .shadow(color: .shade.opacity(on ? 0.1 : 0), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func step(_ d: Int) -> KeyPress.Result {
        let all = SettingsPane.allCases
        guard let i = all.firstIndex(of: selection) else { return .ignored }
        selection = all[min(max(i + d, 0), all.count - 1)]
        return .handled
    }
}
