import Foundation
import CoreAudio
import AudioToolbox

/// Mutes the Mac's speakers while mirroring (sound plays on the TV instead), like AirPlay does.
/// ScreenCaptureKit captures app audio before the output device, so capture keeps working while muted.
/// The previous state is saved in UserDefaults so a crash can't leave the Mac muted.
final class AudioMuter {
    private static let savedKey = "restoreAudio"   // ["device": id, "mute": 0/1] or ["device": id, "volume": x]

    func mute() {
        guard UserDefaults.standard.dictionary(forKey: Self.savedKey) == nil else { return }
        let device = Self.defaultOutputDevice()
        guard device != 0 else { return }
        if let muted = Self.getUInt32(device, kAudioDevicePropertyMute), Self.settable(device, kAudioDevicePropertyMute) {
            UserDefaults.standard.set(["device": Int(device), "mute": Int(muted)], forKey: Self.savedKey)
            Self.setUInt32(device, kAudioDevicePropertyMute, 1)
        } else if let volume = Self.getFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                  Self.settable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
            UserDefaults.standard.set(["device": Int(device), "volume": Double(volume)], forKey: Self.savedKey)
            Self.setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 0)
        }
    }

    /// Safe to call any time; does nothing when nothing was muted.
    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey),
              let id = saved["device"] as? Int else { return }
        let device = AudioDeviceID(id)
        if let mute = saved["mute"] as? Int {
            setUInt32(device, kAudioDevicePropertyMute, UInt32(mute))
        } else if let volume = saved["volume"] as? Double {
            setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(volume))
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, output: Bool = true) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return device
    }

    private static func settable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &ok) == noErr && ok.boolValue
    }

    private static func getUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: UInt32) {
        var addr = address(selector)
        var v = value
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    private static func getFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Float32? {
        var addr = address(selector)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: Float32) {
        var addr = address(selector)
        var v = value
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
