import CoreAudio
import Foundation

/// Other sound off while you dictate: the Mac's output is muted, then put back the way it was.
/// Only a mute YapSketch made is undone, also after a crash (at the next launch).
enum QuietOutput {
    static let key = "muteWhileDictating"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The output YapSketch muted, by UID, so a crash doesn't leave it muted.
    private static let mutedKey = "mutedOutput"

    @MainActor private static var muted: AudioDeviceID?

    @MainActor
    static func begin() {
        guard isOn, muted == nil, let device = defaultOutput(), !isMuted(device), setMute(device, true) else { return }
        muted = device
        UserDefaults.standard.set(uid(device), forKey: mutedKey)
    }

    @MainActor
    static func end() {
        guard let device = muted else { return }
        muted = nil
        setMute(device, false)
        UserDefaults.standard.removeObject(forKey: mutedKey)
    }

    /// At launch: unmutes what a previous run muted and never got to put back.
    @MainActor
    static func recover() {
        guard let uid = UserDefaults.standard.string(forKey: mutedKey) else { return }
        UserDefaults.standard.removeObject(forKey: mutedKey)
        if let device = outputs().first(where: { Self.uid($0) == uid }) { setMute(device, false) }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else {
            return nil
        }
        return id
    }

    private static func outputs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyMute, output: true)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr && value != 0
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, _ on: Bool) -> Bool {
        var a = address(kAudioDevicePropertyMute, output: true)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }
}
