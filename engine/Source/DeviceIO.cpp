// FXRouter host engine — CoreAudio device discovery & configuration helpers.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#include "DeviceIO.h"

#include <CoreFoundation/CoreFoundation.h>

namespace fxrouter {

namespace {

AudioObjectPropertyAddress globalAddr(AudioObjectPropertySelector sel) {
    return {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

std::string cfStringToStd(CFStringRef s) {
    if (!s) return {};
    char buf[512];
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8))
        return std::string(buf);
    return {};
}

std::string getStringProperty(AudioDeviceID id, AudioObjectPropertySelector sel) {
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    auto addr = globalAddr(sel);
    if (AudioObjectGetPropertyData(id, &addr, 0, nullptr, &size, &value) != noErr || !value)
        return {};
    std::string result = cfStringToStd(value);
    CFRelease(value);
    return result;
}

std::vector<AudioDeviceID> allDevices() {
    auto addr = globalAddr(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr)
        return {};
    std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, ids.data()) != noErr)
        return {};
    ids.resize(size / sizeof(AudioDeviceID));
    return ids;
}

bool hasStreamsInScope(AudioDeviceID id, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr = {kAudioDevicePropertyStreams, scope,
                                       kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &addr, 0, nullptr, &size) != noErr)
        return false;
    return size > 0;
}

} // namespace

std::string deviceUID(AudioDeviceID id) {
    return getStringProperty(id, kAudioDevicePropertyDeviceUID);
}

std::string deviceName(AudioDeviceID id) {
    return getStringProperty(id, kAudioDevicePropertyDeviceNameCFString);
}

bool hasOutputStreams(AudioDeviceID id) {
    return hasStreamsInScope(id, kAudioObjectPropertyScopeOutput);
}

bool hasInputStreams(AudioDeviceID id) {
    return hasStreamsInScope(id, kAudioObjectPropertyScopeInput);
}

AudioDeviceID findDeviceByUID(const std::string& uid) {
    for (AudioDeviceID id : allDevices())
        if (deviceUID(id) == uid)
            return id;
    return kAudioObjectUnknown;
}

std::vector<DeviceInfo> listRealOutputDevices() {
    std::vector<DeviceInfo> result;
    for (AudioDeviceID id : allDevices()) {
        if (!hasOutputStreams(id)) continue;
        std::string uid = deviceUID(id);
        if (uid == kVirtualDeviceUID || uid == kVirtualDevice2UID) continue;  // forbidden loop
        result.push_back({id, std::move(uid), deviceName(id)});
    }
    return result;
}

AudioDeviceID systemDefaultOutputDevice() {
    AudioDeviceID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    auto addr = globalAddr(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &id);
    return id;
}

AudioDeviceID suggestedRealOutputDevice() {
    AudioDeviceID def = systemDefaultOutputDevice();
    if (def != kAudioObjectUnknown) {
        std::string uid = deviceUID(def);
        if (uid != kVirtualDeviceUID && uid != kVirtualDevice2UID)
            return def;
    }
    auto outputs = listRealOutputDevices();
    if (outputs.empty()) return kAudioObjectUnknown;
    for (const auto& d : outputs)
        if (d.uid.find("BuiltIn") != std::string::npos || d.uid == "BuiltInSpeakerDevice")
            return d.id;
    return outputs.front().id;
}

bool setSystemDefaultOutputDevice(AudioDeviceID id) {
    auto addr = globalAddr(kAudioHardwarePropertyDefaultOutputDevice);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr,
                                      sizeof(id), &id) == noErr;
}

double getNominalSampleRate(AudioDeviceID id) {
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    auto addr = globalAddr(kAudioDevicePropertyNominalSampleRate);
    AudioObjectGetPropertyData(id, &addr, 0, nullptr, &size, &rate);
    return rate;
}

bool setNominalSampleRate(AudioDeviceID id, double rate) {
    Float64 value = rate;
    auto addr = globalAddr(kAudioDevicePropertyNominalSampleRate);
    return AudioObjectSetPropertyData(id, &addr, 0, nullptr, sizeof(value), &value) == noErr;
}

bool firstStreamIsFloat32(AudioDeviceID id, bool inputScope) {
    AudioObjectPropertyAddress streamsAddr = {
        kAudioDevicePropertyStreams,
        inputScope ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nullptr, &size) != noErr || size == 0)
        return false;
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (AudioObjectGetPropertyData(id, &streamsAddr, 0, nullptr, &size, streams.data()) != noErr)
        return false;

    AudioStreamBasicDescription asbd = {};
    UInt32 asbdSize = sizeof(asbd);
    AudioObjectPropertyAddress fmtAddr = {kAudioStreamPropertyVirtualFormat,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(streams[0], &fmtAddr, 0, nullptr, &asbdSize, &asbd) != noErr)
        return false;
    return asbd.mFormatID == kAudioFormatLinearPCM &&
           (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
           asbd.mBitsPerChannel == 32;
}

} // namespace fxrouter
