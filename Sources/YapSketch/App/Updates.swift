import AppKit
import Sparkle

/// Sparkle checks, downloads and installs from GitHub Releases. What you see is ours: a found
/// update waits as a dot in the menu bar until you open it. Only release builds have a feed
/// (release.sh adds SUFeedURL).
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    static let shared = Updates()
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    struct Release: Codable, Equatable {
        let version: String
        let notes: [String]
        var date: Date?
    }

    enum Phase: Equatable {
        case waiting
        case downloading(Double?)
        case preparing
        case installing
    }

    /// Recording or processing: no background checks then, so no update window pops up on camera.
    var isBusy: () -> Bool = { false }
    /// The dot and the menu line follow `available`.
    var onChange: (() -> Void)?
    /// For the pill: what a check by hand found, or that an update just went in.
    var onNotice: ((Notice) -> Void)?

    enum Notice {
        case upToDate(String)
        case failed
        case updated(Release)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .waiting

    private var updater: SPUUpdater?
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelDownload: (() -> Void)?
    private var checkingByHand = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        announceIfUpdated()
        guard Self.isEnabled else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try u.start()
            updater = u
        } catch {
            Log.info("updates: couldn't start (\(error.localizedDescription))")
        }
    }

    func checkForUpdates() {
        if available != nil { return UpdateWindow.shared.show() }
        guard let updater, updater.canCheckForUpdates else { return }
        checkingByHand = true
        updater.checkForUpdates()
    }

    /// Downloads in the background and installs when YapSketch quits.
    var updatesByItself: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            updater?.automaticallyChecksForUpdates = true
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    /// The notes of the version running now, when it came as an update.
    var currentNotes: Release? {
        guard let saved = Self.savedRelease, saved.version == Self.currentVersion else { return nil }
        return saved
    }

    func install() {
        guard let reply else { return }
        self.reply = nil
        phase = .downloading(nil)
        reply(.install)
    }

    func cancel() {
        cancelDownload?()
    }

    #if DEBUG
    func debugSet(_ release: Updates.Release?, phase: Phase) {
        available = release
        self.phase = phase
    }
    #endif

    // MARK: Telling you once it went in

    private static var savedRelease: Release? {
        get { UserDefaults.standard.data(forKey: "updateNotes").flatMap { try? JSONDecoder().decode(Release.self, from: $0) } }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "updateNotes") }
    }

    private func announceIfUpdated() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: "lastVersion")
        defaults.set(Self.currentVersion, forKey: "lastVersion")
        guard let last, last != Self.currentVersion, let notes = currentNotes else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.onNotice?(.updated(notes)) }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, MainActor.assumeIsolated({ isBusy() }) else { return }
        throw NSError(domain: "YapSketch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Busy recording"])
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.savedRelease = Self.release(item)
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        available = Self.release(appcastItem)
        phase = .waiting
        onChange?()
        if state.userInitiated || checkingByHand { UpdateWindow.shared.show() }
        checkingByHand = false
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if checkingByHand { onNotice?(.upToDate(Self.currentVersion)) }
        checkingByHand = false
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Log.info("updates: \(error.localizedDescription)")
        if checkingByHand || phase != .waiting { onNotice?(.failed) }
        checkingByHand = false
        clear()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        expected = 0
        received = 0
        phase = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        received = 0
        phase = .downloading(0)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        phase = .downloading(expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        phase = .preparing
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    /// You already chose Update and reopen.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .installing
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        if available != nil { UpdateWindow.shared.show() }
    }

    func dismissUpdateInstallation() {
        clear()
    }

    private func clear() {
        reply = nil
        cancelDownload = nil
        available = nil
        phase = .waiting
        UpdateWindow.shared.close()
        onChange?()
    }

    /// The release notes are the appcast item's description: one point per line (a leading "-",
    /// "*" or "•" is dropped, as are headings and any HTML tags).
    static func release(_ item: SUAppcastItem) -> Release {
        let text = (item.itemDescription ?? "")
            .replacingOccurrences(of: "<li>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
        let notes = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                var l = Substring(line)
                while let c = l.first, "-*•".contains(c) { l = l.dropFirst() }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return Release(version: item.displayVersionString, notes: notes, date: item.date)
    }
}
