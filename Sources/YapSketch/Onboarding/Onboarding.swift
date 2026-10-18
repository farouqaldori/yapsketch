import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// The page it's on is saved, so after Quit & Reopen (Screen Recording needs one) it opens
/// right there again.
@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()

    enum Step: Hashable {
        case welcome
        case speech(SpeechStage)
        case smartPictures
        case permission(Permission)
        case done
    }

    enum SpeechStage: Hashable {
        case choose, localModels, downloading, cloud, cloudModels
    }

    @Published var step: Step = .welcome {
        didSet { if step != oldValue { stepChanged() } }
    }
    @Published private(set) var granted: Set<Permission> = []
    @Published var openedSettings = false
    /// Screen Recording is switched on, but only takes effect once the app reopens.
    @Published private(set) var needsReopen = false
    /// The microphone was refused once: macOS won't ask again, so it's System Settings.
    @Published private(set) var micDenied = false

    @Published var useCloud = CloudSpeech.selected() != nil
    @Published var localModel = ModelStore.catalog.contains { $0.id == ModelStore.shared.selectedID } ? ModelStore.shared.selectedID : "parakeet-unified"
    @Published var cloudProvider: String? = CloudSpeech.selected()?.providerID
    @Published var showJevAccounts = false

    var onStartRecording: (() -> Void)?

    private var window: NSWindow?
    private var timer: Timer?
    private var advance: DispatchWorkItem?
    private let helper = SettingsHelper()
    private let defaults = UserDefaults.standard
    /// Off in the snapshots: nothing saved, the real permissions not read.
    private var live = true
    /// macOS 15's own "bypass the private window picker" prompt has been raised this launch.
    private var askedForCapture = false

    private var finished: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    private var savedStep: Permission? {
        get { defaults.string(forKey: "onboardingStep").flatMap(Permission.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "onboardingStep") }
    }

    private var atEnd: Bool {
        get { defaults.bool(forKey: "onboardingAtEnd") }
        set { defaults.set(newValue, forKey: "onboardingAtEnd") }
    }

    // MARK: Showing

    func showIfNeeded() {
        refresh()
        if !finished || savedStep != nil { show() }
    }

    func show(at permission: Permission? = nil) {
        refresh()
        if let p = permission ?? savedStep {
            step = .permission(p)
        } else if !finished {
            step = atEnd ? .done : .welcome
        } else {
            step = firstMissing.map { .permission($0) } ?? .done
        }
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startPolling()
        if case .permission(let p) = step, granted.contains(p) { scheduleAdvance() }
    }

    func makeWindow() -> NSWindow {
        Brand.registerFonts()
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Welcome to YapSketch"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .aqua)
        w.backgroundColor = Brand.paper
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // No system focus ring: it shows with keyboard navigation on and clashes.
        let host = NSHostingController(rootView: OnboardingView(model: self).focusEffectDisabled())
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(CGSize(width: 720, height: 500))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        return w
    }

    private func closed() {
        if live, step == .done {
            finished = true
            atEnd = false
        }
        timer?.invalidate()
        timer = nil
        advance?.cancel()
        helper.hide()
    }

    // MARK: Moving between pages

    var firstMissing: Permission? { Permission.allCases.first { !granted.contains($0) } }

    var next: Step {
        switch step {
        case .welcome: return .speech(.choose)
        case .speech: return .smartPictures
        case .smartPictures, .done: return firstMissing.map { .permission($0) } ?? .done
        case .permission(let p):
            let i = Permission.allCases.firstIndex(of: p) ?? 0
            let after = Array(Permission.allCases[(i + 1)...]) + Array(Permission.allCases[..<i])
            return after.first { !granted.contains($0) }.map { .permission($0) } ?? .done
        }
    }

    func goNext() {
        advance?.cancel()
        step = next
    }

    func goBack() {
        advance?.cancel()
        switch step {
        case .permission(let p):
            let i = Permission.allCases.firstIndex(of: p) ?? 0
            step = i == 0 ? .smartPictures : .permission(Permission.allCases[i - 1])
        case .smartPictures: step = .speech(useCloud ? .cloudModels : .localModels)
        case .speech(.downloading): step = .speech(.localModels)
        case .speech(.cloudModels): step = .speech(.cloud)
        case .speech(.localModels), .speech(.cloud): step = .speech(.choose)
        case .speech(.choose), .welcome, .done: step = .welcome
        }
    }

    // MARK: Speech and smart pictures

    func pickLocal(_ m: SpeechModel) {
        useCloud = false
        localModel = m.id
        let store = ModelStore.shared
        store.selectedID = m.id
        NotificationCenter.default.post(name: .yapSketchModelChanged, object: nil)
        if store.installed.contains(m.id) {
            step = .smartPictures
        } else {
            store.download(m)
            step = .speech(.downloading)
        }
    }

    func pickCloud(_ m: CloudModel) {
        useCloud = true
        cloudProvider = m.providerID
        let store = ModelStore.shared
        // A small model on this Mac too, for when the provider can't be reached.
        if store.installed.isEmpty, let backup = ModelStore.catalog.first(where: { $0.id == "whisper-small" }) {
            store.download(backup)
        }
        store.selectedID = m.id
        if m.provider?.jev != nil, (defaults.string(forKey: "jevProvider") ?? "").isEmpty {
            defaults.set(m.providerID, forKey: "jevProvider")
        }
        NotificationCenter.default.post(name: .yapSketchModelChanged, object: nil)
        step = .smartPictures
    }

    func useJev(_ providerID: String) {
        defaults.set(true, forKey: "smartPictures")
        defaults.set(providerID, forKey: "jevProvider")
        showJevAccounts = false
    }

    private func stepChanged() {
        openedSettings = false
        needsReopen = false
        helper.hide()
        guard live else { return }
        switch step {
        case .permission(let p):
            savedStep = p
            atEnd = false
        case .done:
            savedStep = nil
            atEnd = true
        case .welcome, .speech, .smartPictures: atEnd = false
        }
        refresh()
    }

    /// Ticked: a moment to see it, then the next page.
    private func scheduleAdvance() {
        advance?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.goNext() }
        advance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: Asking

    func ask(_ p: Permission) {
        if p == .microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    // Apple's recognizer is the fallback for live captions; it asks once too.
                    if ok { AppleSpeech.requestAuthorization { _ in } }
                    self.refresh()
                }
            }
            return
        }
        openSettings(p)
    }

    func openSettings(_ p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
        openedSettings = true
        if p != .microphone, let i = Permission.allCases.firstIndex(of: p) {
            helper.show(permission: p, index: i + 1, of: Permission.allCases.count)
        }
    }

    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    /// Screen Recording only applies to a fresh process.
    func reopen() {
        reopenAfterQuit()
        NSApp.terminate(nil)
    }

    private var reopening = false

    /// Asked to quit while System Settings is open for a permission: macOS's own Quit & Reopen,
    /// which often doesn't reopen a menu-bar app. So YapSketch reopens itself.
    var quitIsForPermission: Bool {
        guard case .permission = step, openedSettings, window?.isVisible == true else { return false }
        return true
    }

    /// Opens YapSketch again once this process has exited (if macOS already did, it's just
    /// brought forward).
    func reopenAfterQuit() {
        guard !reopening else { return }
        reopening = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
    }

    func startRecording() {
        finished = true
        atEnd = false
        window?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onStartRecording?() }
    }

    // MARK: Watching for the switch

    private func startPolling() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let was = granted
        let now = Set(Permission.allCases.filter(\.isGranted))
        if now != granted { granted = now }
        let denied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        if denied != micDenied { micDenied = denied }
        guard case .permission(let p) = step else { return }
        if p == .screenRecording, granted.contains(p) { raiseCapturePrompt() }
        if p == .screenRecording, !granted.contains(p) {
            let reopen = Self.canSeeWindowTitles()
            if reopen != needsReopen { needsReopen = reopen }
            if reopen { helper.hide() }
        }
        if granted.contains(p), !was.contains(p) {
            helper.hide()
            if openedSettings || p == .microphone {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            scheduleAdvance()
        }
    }

    /// With Screen Recording on, macOS 15 still asks once more ("bypass the system private
    /// window picker") the first time the screen is listed. Listing it here brings that up
    /// during the welcome, instead of in the middle of the first recording.
    private func raiseCapturePrompt() {
        guard live, !askedForCapture else { return }
        askedForCapture = true
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    /// Screen Recording, switched on since launch: other apps' window titles become readable
    /// at once, though capturing needs a new process (CGPreflightScreenCaptureAccess stays false).
    private static func canSeeWindowTitles() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { w in
            (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerPID as String] as? Int32) != me
                && !((w[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    #if DEBUG
    func debugSet(_ step: Step, granted: Set<Permission>, openedSettings: Bool = false, needsReopen: Bool = false) {
        live = false
        self.step = step
        self.granted = granted
        self.openedSettings = openedSettings
        self.needsReopen = needsReopen
    }
    #endif
}
