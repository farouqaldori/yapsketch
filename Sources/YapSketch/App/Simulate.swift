import Foundation

/// A problem picked in the menu's Simulate a Problem happens once, on the next recording, through
/// the real path. The menu shows with `defaults write com.yapsketch.app debugMenu -bool true`.
enum Simulate: String, CaseIterable {
    case noScreenRecording, noMicrophone, lowSpace, cantStart, slowStart
    case stopsEarly, slowReport, noReport, quitWhileProcessing

    var title: String {
        switch self {
        case .noScreenRecording: "Screen Recording is off"
        case .noMicrophone: "Microphone is off"
        case .lowSpace: "Disk almost full"
        case .cantStart: "Capture fails to start"
        case .slowStart: "Capture never starts (20 s)"
        case .stopsEarly: "Disk fills up while recording"
        case .slowReport: "Report takes too long"
        case .noReport: "Report can't be made"
        case .quitWhileProcessing: "App quits while making the report"
        }
    }

    private static let key = "simulateProblem"
    static var showsMenu: Bool { UserDefaults.standard.bool(forKey: "debugMenu") }

    static var pending: Simulate? {
        get { UserDefaults.standard.string(forKey: key).flatMap(Simulate.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
    }

    /// Whether `kind` is the one to simulate now (it's used up).
    static func take(_ kind: Simulate) -> Bool {
        guard showsMenu, pending == kind else { return false }
        pending = nil
        Log.info("simulating: \(kind.title)")
        return true
    }
}
