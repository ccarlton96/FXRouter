// FXRouter host engine — public interface.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// Phase 2: passthrough loop. Reads the FXRouter virtual device's input
// side, moves samples through a tolerant ring buffer, writes to a real output
// device. Phase 3 replaces the ring buffer with adaptive resampling; Phase 4
// inserts the JUCE plugin graph between read and write.

#pragma once

#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <cstdint>
#include <string>

#include "PluginChain.h"
#include "Resampler.h"
#include "RingBuffer.h"

namespace fxrouter {

class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();

    AudioEngine(const AudioEngine&) = delete;
    AudioEngine& operator=(const AudioEngine&) = delete;

    // Opens the virtual device's input side and the given real output device,
    // then starts the passthrough. Returns false with lastError() set on
    // failure. Rejects the virtual device itself as output (forbidden loop).
    // preferredBufferFrames: requested device IO buffer size — smaller is
    // lower latency, larger is more dropout-resistant (E5 setting).
    bool start(AudioDeviceID outputDevice, uint32_t preferredBufferFrames = 256);
    void stop();
    bool isRunning() const { return running_; }

    const std::string& lastError() const { return lastError_; }

    double sampleRate() const { return sampleRate_; }
    AudioDeviceID outputDevice() const { return outputDevice_; }

    // Cumulative dropouts: producer-side overruns + consumer-side underruns.
    // With the drift servo active these should stay at zero in steady state.
    uint64_t dropoutCount() const { return resampler_.underruns() + ring_.overruns(); }

    // Live drift correction being applied, in parts per million.
    int32_t driftPPM() const { return resampler_.ratioPPM(); }

    // Ring fill in frames (current / servo target).
    uint32_t bufferFillFrames() const { return resampler_.fillFrames(); }
    uint32_t bufferTargetFrames() const { return resampler_.targetFill(); }

    // The hosted-plugin stage (Phase 4: single hardcoded reverb).
    PluginChain& pluginChain() { return chain_; }

    // Signal presence meters (RMS of the latest callback, linear 0..1).
    // Nonzero input = the system is feeding us; nonzero output = we are
    // producing sound. The difference localizes "silence" bugs instantly.
    float inputLevel() const { return inLevel_.load(std::memory_order_relaxed); }
    float outputLevel() const { return outLevel_.load(std::memory_order_relaxed); }

    // Backlog hard-resyncs performed (each one is a single audible skip).
    uint64_t resyncCount() const { return resampler_.resyncs(); }

private:
    static OSStatus inputProc(AudioObjectID device, const AudioTimeStamp* now,
                              const AudioBufferList* inputData, const AudioTimeStamp* inputTime,
                              AudioBufferList* outputData, const AudioTimeStamp* outputTime,
                              void* clientData);
    static OSStatus outputProc(AudioObjectID device, const AudioTimeStamp* now,
                               const AudioBufferList* inputData, const AudioTimeStamp* inputTime,
                               AudioBufferList* outputData, const AudioTimeStamp* outputTime,
                               void* clientData);

    bool fail(std::string message);  // sets lastError_, returns false

    AudioDeviceID inputDevice_ = kAudioObjectUnknown;   // our virtual device
    AudioDeviceID outputDevice_ = kAudioObjectUnknown;  // real output
    AudioDeviceIOProcID inputProcID_ = nullptr;
    AudioDeviceIOProcID outputProcID_ = nullptr;
    bool inputStarted_ = false;
    bool outputStarted_ = false;

    StereoRingBuffer ring_;
    AdaptiveResampler resampler_;
    PluginChain chain_;
    std::atomic<bool> running_{false};
    std::atomic<bool> outputTicked_{false};
    std::atomic<float> inLevel_{0.0f};
    std::atomic<float> outLevel_{0.0f};
    double sampleRate_ = 0;
    std::string lastError_;
};

} // namespace fxrouter
