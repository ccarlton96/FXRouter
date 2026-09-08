// FXRouter host engine — CoreAudio device discovery & configuration helpers.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// Non-real-time utilities only. Nothing here may be called from an IOProc.

#pragma once

#include <CoreAudio/CoreAudio.h>
#include <string>
#include <vector>

namespace fxrouter {

// UIDs of our own virtual device (must match driver/FXRouter.c).
inline constexpr const char* kVirtualDeviceUID  = "com.fxrouter.audio.device";
inline constexpr const char* kVirtualDevice2UID = "com.fxrouter.audio.device2";

struct DeviceInfo {
    AudioDeviceID id = kAudioObjectUnknown;
    std::string uid;
    std::string name;
};

// 0 / kAudioObjectUnknown if not found.
AudioDeviceID findDeviceByUID(const std::string& uid);

// All devices with at least one output stream, EXCLUDING our own virtual
// device — routing our own output back into our input would loop.
std::vector<DeviceInfo> listRealOutputDevices();

std::string deviceUID(AudioDeviceID id);
std::string deviceName(AudioDeviceID id);

AudioDeviceID systemDefaultOutputDevice();

// The device Phase 2 should output to: the system default output unless that
// is our virtual device, otherwise the first real output (preferring built-in).
AudioDeviceID suggestedRealOutputDevice();

double getNominalSampleRate(AudioDeviceID id);
bool setNominalSampleRate(AudioDeviceID id, double rate);   // may apply asynchronously

// Changes the SYSTEM default output device (used by onboarding to route the
// system into FXRouter, and by the quit flow to route it back out — F1).
bool setSystemDefaultOutputDevice(AudioDeviceID id);

// True if the device's first output/input stream is 32-bit float PCM
// (the only format the Phase 2 passthrough handles).
bool firstStreamIsFloat32(AudioDeviceID id, bool inputScope);

bool hasOutputStreams(AudioDeviceID id);
bool hasInputStreams(AudioDeviceID id);

} // namespace fxrouter
