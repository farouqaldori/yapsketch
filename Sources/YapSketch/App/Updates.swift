import AppKit
import Sparkle

/// Sparkle updates from GitHub Releases. Only release builds have a feed (release.sh adds SUFeedURL).
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    /// Recording or processing: no background checks then, so no update window pops up on camera.
    var isBusy: () -> Bool = { false }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var updater: SPUUpdater { controller.updater }

    func start() {
        guard Self.isEnabled else { return }
        controller.startUpdater()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { Self.isEnabled && updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, MainActor.assumeIsolated({ isBusy() }) else { return }
        throw NSError(domain: "YapSketch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Busy recording"])
    }

    /// A menu bar app: a found update shows up behind other windows instead of taking focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
