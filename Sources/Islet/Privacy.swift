import CoreAudio
import CoreMediaIO
import SwiftUI

/// Mic and camera in use (by any app), plus a system-wide mic mute.
/// CoreAudio / CoreMediaIO property listeners: no polling.
@MainActor @Observable
final class PrivacyMonitor {
    private(set) var micInUse = false
    private(set) var cameraInUse = false
    private(set) var micMuted = false
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var input: AudioObjectID = 0
    @ObservationIgnored private var listenedAudio: Set<AudioObjectID> = []
    @ObservationIgnored private var listenedCameras: Set<CMIOObjectID> = []
    @ObservationIgnored private var cameras: [CMIOObjectID] = []
    @ObservationIgnored private var savedVolume: Float32?

    func start() {
        var addr = Self.audio(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindInput() }
        }
        bindInput()
        var devs = Self.cmio(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devs, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindCameras() }
        }
        bindCameras()
    }

    /// All Mute: mutes the default input device for every app (falls back to input volume 0).
    func toggleMute() {
        let mute = !micMuted
        var addr = Self.audio(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(input, &addr), AudioObjectIsPropertySettable(input, &addr, &settable) == noErr, settable.boolValue {
            var v: UInt32 = mute ? 1 : 0
            AudioObjectSetPropertyData(input, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        } else {
            var vol = Self.audio(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
            if mute { savedVolume = Self.get(input, vol, Float32(1)) }
            var v: Float32 = mute ? 0 : (savedVolume ?? 0.75)
            AudioObjectSetPropertyData(input, &vol, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if !mute { savedVolume = nil }
        }
        refreshMic()
    }

    private func bindInput() {
        input = Self.get(AudioObjectID(kAudioObjectSystemObject), Self.audio(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0))
        if input != 0, !listenedAudio.contains(input) {
            listenedAudio.insert(input)
            for (sel, scope) in [(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
                                 (kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput),
                                 (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput)] {
                var a = Self.audio(sel, scope: scope)
                guard AudioObjectHasProperty(input, &a) else { continue }
                AudioObjectAddPropertyListenerBlock(input, &a, .main) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshMic() }
                }
            }
        }
        refreshMic()
    }

    private func refreshMic() {
        let running: UInt32 = Self.get(input, Self.audio(kAudioDevicePropertyDeviceIsRunningSomewhere), 0)
        let muteFlag: UInt32 = Self.get(input, Self.audio(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput), 0)
        let muted = muteFlag != 0 || savedVolume != nil
        if (running != 0) != micInUse || muted != micMuted {
            micInUse = running != 0
            micMuted = muted
            onChange()
        }
    }

    private func bindCameras() {
        var addr = Self.cmio(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size)
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids)
        cameras = ids
        for id in ids where !listenedCameras.contains(id) {
            listenedCameras.insert(id)
            var a = Self.cmio(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(id, &a, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            }
        }
        refreshCameras()
    }

    private func refreshCameras() {
        let on = cameras.contains { id in
            var a = Self.cmio(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var v: UInt32 = 0, used: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &v) == 0 && v != 0
        }
        if on != cameraInUse { cameraInUse = on; onChange() }
    }

    private static func audio(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func cmio(_ sel: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func get<T>(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ fallback: T) -> T {
        var a = address
        var v = fallback
        var size = UInt32(MemoryLayout<T>.size)
        guard obj != 0, AudioObjectHasProperty(obj, &a), AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return fallback }
        return v
    }
}

/// Mic / camera status and All Mute, in the strip right of the notch while either is in use.
struct PrivacyButtons: View {
    let privacy: PrivacyMonitor

    var body: some View {
        if privacy.micInUse || privacy.cameraInUse {
            HStack(spacing: 4) {
                if privacy.cameraInUse {
                    Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.green).help("Camera in use")
                }
                Button(action: privacy.toggleMute) {
                    Image(systemName: privacy.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(privacy.micMuted ? .red : .orange)
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(privacy.micMuted ? "Unmute microphone (all apps)" : "Mute microphone (all apps)")
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}
