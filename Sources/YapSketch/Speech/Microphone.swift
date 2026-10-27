import AVFoundation
import CoreAudio

/// The microphone YapSketch listens with: the one chosen in Settings, or the Mac's default
/// input when none is chosen or the chosen one isn't connected.
enum Microphone {
    struct Device: Identifiable, Hashable {
        /// Core Audio's UID, which is also the capture device's `uniqueID`.
        let id: String
        let name: String
        let builtIn: Bool
    }

    /// Settings key; empty for the Mac's default.
    static let key = "microphone"

    static var chosenID: String? {
        UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every connected device with an input.
    static func all() -> [Device] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = number(id, kAudioDevicePropertyTransportType)
            return Device(id: uid, name: name, builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// The chosen device, if it's connected.
    static func chosen() -> (uid: String, device: AudioDeviceID)? {
        guard let uid = chosenID, let device = deviceIDs().first(where: { string($0, kAudioDevicePropertyDeviceUID) == uid }) else {
            return nil
        }
        return (uid, device)
    }

    /// What a recording captures: the chosen microphone, else the default one.
    static var captureUID: String? { chosen()?.uid ?? AVCaptureDevice.default(for: .audio)?.uniqueID }

    /// The default input's name, for "Same as macOS (…)".
    static func defaultName() -> String? {
        guard let id = number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice), id != 0 else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    /// Points an engine's input at the chosen microphone. Before the engine starts.
    static func use(on engine: AVAudioEngine) {
        guard let chosen = chosen(), let unit = engine.inputNode.audioUnit else { return }
        var device = chosen.device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.info("microphone: couldn't switch to the chosen one (\(status))") }
    }

    /// Calls back on the main queue when a device is connected or disconnected, or the
    /// default changes. Keep the token for as long as it should.
    static func watch(_ changed: @escaping @Sendable () -> Void) -> AnyObject {
        Watcher(changed)
    }

    private final class Watcher {
        private let block: AudioObjectPropertyListenerBlock
        private let addresses: [AudioObjectPropertyAddress] = [
            address(kAudioHardwarePropertyDevices), address(kAudioHardwarePropertyDefaultInputDevice),
        ]

        init(_ changed: @escaping @Sendable () -> Void) {
            block = { _, _ in changed() }
            for var a in addresses {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
            }
        }

        deinit {
            for var a in addresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
            }
        }
    }

    // MARK: Core Audio

    private static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    /// A 32-bit property: a device ID, a transport type.
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}
