import Foundation
import AppKit
import CoreAudio
import AudioToolbox

/// Brightness, volume, display sleep, and screen lock for the client's hardware sheet.
@MainActor
enum HardwareController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServicesHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    }()

    /// NSAppleScript isn't thread-safe; every script runs on this one queue.
    private static let scriptQueue = DispatchQueue(label: "rd.hardware.applescript", qos: .userInitiated)

    static func getBrightness() -> Float {
        guard let handle = displayServicesHandle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return 0.5 }
        let fn = unsafeBitCast(sym, to: GetBrightness.self)
        var brightness: Float = 0.5
        _ = fn(CGMainDisplayID(), &brightness)
        return max(0.0, min(1.0, brightness))
    }

    static func setBrightness(_ value: Float) {
        guard value.isFinite,
              let handle = displayServicesHandle,
              let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return }
        let fn = unsafeBitCast(sym, to: SetBrightness.self)
        _ = fn(CGMainDisplayID(), max(0.0, min(1.0, value)))
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &propertyAddress, 0, nil, &propertySize, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static func getVolumeSettings() -> (volume: Int, isMuted: Bool) {
        guard let deviceID = defaultOutputDeviceID() else {
            return (50, false)
        }

        var vol: Float32 = 0.5
        var volAddress = volumeAddress
        var volSize = UInt32(MemoryLayout<Float32>.size)
        let volStatus = AudioObjectGetPropertyData(deviceID, &volAddress, 0, nil, &volSize, &vol)

        var isMuted: UInt32 = 0
        var mute = muteAddress
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(deviceID, &mute, 0, nil, &muteSize, &isMuted)

        let volumeInt = volStatus == noErr ? Int(round(vol * 100.0)) : 50
        let mutedBool = muteStatus == noErr ? (isMuted != 0) : false

        return (max(0, min(100, volumeInt)), mutedBool)
    }

    static func setVolume(_ volume: Int) {
        let clamped = max(0, min(100, volume))
        if let deviceID = defaultOutputDeviceID() {
            var vol = Float32(clamped) / 100.0
            var address = volumeAddress
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
        // Some output devices ignore the CoreAudio property; the AppleScript route covers them.
        runScript("set volume output volume \(clamped)")
    }

    static func setMuted(_ muted: Bool) {
        if let deviceID = defaultOutputDeviceID() {
            var isMuted: UInt32 = muted ? 1 : 0
            var address = muteAddress
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &isMuted)
        }
        runScript("set volume output muted \(muted ? "true" : "false")")
    }

    private static func runScript(_ source: String) {
        scriptQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    static func sleepDisplay() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
        }
    }

    static func lockScreen() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias SACLockScreenImmediateType = @convention(c) () -> Void
            let fn = unsafeBitCast(sym, to: SACLockScreenImmediateType.self)
            fn()
        } else {
            InputInjector.key(code: 12, down: true, flags: [.maskControl, .maskCommand])
            InputInjector.key(code: 12, down: false, flags: [.maskControl, .maskCommand])
        }
    }

    static func getState() -> RDHardwareControls {
        let (vol, muted) = getVolumeSettings()
        return RDHardwareControls(brightness: getBrightness(), volume: vol, isMuted: muted)
    }
}
