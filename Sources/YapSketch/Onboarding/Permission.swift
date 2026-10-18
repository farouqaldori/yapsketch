import AVFoundation
import AppKit

/// In the order the welcome asks for them.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, screenRecording, accessibility, inputMonitoring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: "To hear what you say"
        case .screenRecording: "To see what you show"
        case .accessibility: "To paste where you're typing"
        case .inputMonitoring: "For your shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .screenRecording: "display"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    /// Its list in System Settings › Privacy & Security, as it's titled there.
    var settingsTitle: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var settingsURL: URL {
        let anchor =
            switch self {
            case .microphone: "Privacy_Microphone"
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    static var missing: [Permission] { allCases.filter { !$0.isGranted } }
    static var allGranted: Bool { missing.isEmpty }
}
