// Helper for uninstall.sh: if the current default output device is the
// FXRouter virtual device, switch to the built-in speakers so the user is
// never left in silence.
// Runs via: swift installer/restore-output.swift
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

import CoreAudio
import Foundation

func getDefaultOutput() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    return deviceID
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return status == noErr ? uid as String : nil
}

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

let fxrouterUID = "com.fxrouter.audio.device"
let currentUID = deviceUID(getDefaultOutput())

if currentUID == fxrouterUID || currentUID == nil {
    // Prefer built-in speakers; fall back to any output device that isn't ours.
    var candidate: AudioDeviceID?
    for id in allDevices() {
        guard let uid = deviceUID(id), uid != fxrouterUID, uid != "com.fxrouter.audio.device2" else { continue }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard size > 0 else { continue }  // not an output device
        if uid == "BuiltInSpeakerDevice" || uid.contains("AppleHDA") || uid.contains("BuiltIn") {
            candidate = id
            break
        }
        if candidate == nil { candidate = id }
    }
    if var newID = candidate {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &newID)
        print("Default output switched away from FXRouter.")
    } else {
        print("WARNING: no alternative output device found; set one in System Settings → Sound.")
    }
} else {
    print("Default output is not FXRouter; nothing to restore.")
}
