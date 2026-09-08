// FXRouter host engine — Phase 2 passthrough implementation.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#include "AudioEngine.h"

#include <cmath>
#include <unistd.h>

#include "DeviceIO.h"

namespace fxrouter {

namespace {
// Max frames handled per stack chunk inside an IOProc (no heap on RT threads).
constexpr uint32_t kChunkFrames = 512;

// Requested device IO buffer size. Smaller = lower latency; 256 frames is
// comfortable on Apple Silicon. Becomes a user setting in Phase 7.
// RT-SAFE: plain arithmetic over the callback's samples, no calls out.
float rmsOf(const float* samples, uint32_t count) {
    if (count == 0) return 0.0f;
    float sum = 0.0f;
    for (uint32_t i = 0; i < count; ++i) sum += samples[i] * samples[i];
    return std::sqrt(sum / static_cast<float>(count));
}

UInt32 setAndGetBufferFrames(AudioDeviceID device, UInt32 preferred) {
    AudioObjectPropertyAddress addr = {kAudioDevicePropertyBufferFrameSize,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    UInt32 frames = preferred;
    AudioObjectSetPropertyData(device, &addr, 0, nullptr, sizeof(frames), &frames);
    UInt32 size = sizeof(frames);
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &frames) != noErr)
        frames = 512;  // conservative assumption if unreadable
    return frames;
}
} // namespace

AudioEngine::AudioEngine() = default;
AudioEngine::~AudioEngine() { stop(); }

bool AudioEngine::fail(std::string message) {
    lastError_ = std::move(message);
    stop();
    return false;
}

bool AudioEngine::start(AudioDeviceID outputDevice, uint32_t preferredBufferFrames) {
    stop();
    lastError_.clear();

    inputDevice_ = findDeviceByUID(kVirtualDeviceUID);
    if (inputDevice_ == kAudioObjectUnknown)
        return fail("FXRouter device not found — is the driver installed? (installer/install.sh)");

    // Forbidden-loop rule (F2): never output into ourselves.
    const std::string outUID = deviceUID(outputDevice);
    if (outputDevice == kAudioObjectUnknown || outUID.empty())
        return fail("No output device selected.");
    if (outUID == kVirtualDeviceUID || outUID == kVirtualDevice2UID)
        return fail("Refusing to output to FXRouter itself (feedback loop).");
    if (!hasOutputStreams(outputDevice))
        return fail("Selected device has no outputs: " + deviceName(outputDevice));

    // Phase 2 has no resampler: run the virtual device at the output's rate.
    const double outRate = getNominalSampleRate(outputDevice);
    if (getNominalSampleRate(inputDevice_) != outRate) {
        setNominalSampleRate(inputDevice_, outRate);
        // The rate change propagates asynchronously through coreaudiod.
        for (int i = 0; i < 50 && getNominalSampleRate(inputDevice_) != outRate; ++i)
            usleep(10 * 1000);
        if (getNominalSampleRate(inputDevice_) != outRate)
            return fail("Could not match sample rates (virtual device refused " +
                        std::to_string(outRate) + " Hz).");
    }
    sampleRate_ = outRate;

    if (!firstStreamIsFloat32(inputDevice_, /*inputScope=*/true))
        return fail("Virtual device input is not Float32 PCM (unexpected driver build).");
    if (!firstStreamIsFloat32(outputDevice, /*inputScope=*/false))
        return fail("Output device is not Float32 PCM; not supported in Phase 2: " +
                    deviceName(outputDevice));

    outputDevice_ = outputDevice;

    // Keep callbacks small for latency, and size the servo's fill target off
    // the actual granted buffer sizes: 3× the larger side gives enough cushion
    // for callback phasing while staying within the ~30 ms latency budget.
    const UInt32 clamped = preferredBufferFrames < 64 ? 64
                         : preferredBufferFrames > 2048 ? 2048 : preferredBufferFrames;
    const UInt32 inBuf = setAndGetBufferFrames(inputDevice_, clamped);
    const UInt32 outBuf = setAndGetBufferFrames(outputDevice_, clamped);
    const UInt32 maxBuf = inBuf > outBuf ? inBuf : outBuf;
    ring_.reset();
    resampler_.configure(3 * maxBuf);
    outputTicked_ = false;
    // IOProcs are stopped here, so re-preparing the hosted plugin is safe.
    chain_.setPlayConfig(outRate, outBuf > kChunkFrames ? outBuf : kChunkFrames);

    if (AudioDeviceCreateIOProcID(inputDevice_, &AudioEngine::inputProc, this, &inputProcID_) != noErr)
        return fail("Failed to attach to the virtual device (microphone permission denied?).");
    if (AudioDeviceCreateIOProcID(outputDevice_, &AudioEngine::outputProc, this, &outputProcID_) != noErr)
        return fail("Failed to attach to the output device: " + deviceName(outputDevice_));

    running_ = true;  // set before starting so IOProcs see it
    if (AudioDeviceStart(inputDevice_, inputProcID_) != noErr)
        return fail("Failed to start the virtual device input.");
    inputStarted_ = true;
    if (AudioDeviceStart(outputDevice_, outputProcID_) != noErr)
        return fail("Failed to start the output device: " + deviceName(outputDevice_));
    outputStarted_ = true;

    return true;
}

void AudioEngine::stop() {
    running_ = false;
    if (inputStarted_) AudioDeviceStop(inputDevice_, inputProcID_);
    if (outputStarted_) AudioDeviceStop(outputDevice_, outputProcID_);
    inputStarted_ = outputStarted_ = false;
    if (inputProcID_) AudioDeviceDestroyIOProcID(inputDevice_, inputProcID_);
    if (outputProcID_) AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
    inputProcID_ = outputProcID_ = nullptr;
}

// RT-SAFE: reads the virtual device's loopback input into the ring buffer.
// No allocation (fixed stack chunk), no locks (SPSC ring uses atomics only),
// no I/O, no ObjC/Swift.
OSStatus AudioEngine::inputProc(AudioObjectID, const AudioTimeStamp*,
                                const AudioBufferList* inputData, const AudioTimeStamp*,
                                AudioBufferList*, const AudioTimeStamp*, void* clientData) {
    auto* self = static_cast<AudioEngine*>(clientData);
    if (!self->running_.load(std::memory_order_relaxed)) return noErr;
    if (!inputData || inputData->mNumberBuffers == 0) return noErr;

    const AudioBuffer& buf = inputData->mBuffers[0];
    const auto* src = static_cast<const float*>(buf.mData);
    const uint32_t channels = buf.mNumberChannels;
    if (!src || channels == 0) return noErr;
    uint32_t frames = buf.mDataByteSize / (channels * sizeof(float));

    self->inLevel_.store(rmsOf(src, frames * channels), std::memory_order_relaxed);

    if (channels == 2) {
        self->ring_.write(src, frames);
        return noErr;
    }
    // Non-stereo input: repack first-2 / duplicated-mono in stack chunks.
    float chunk[kChunkFrames * 2];
    while (frames > 0) {
        const uint32_t n = frames < kChunkFrames ? frames : kChunkFrames;
        for (uint32_t i = 0; i < n; ++i) {
            chunk[i * 2]     = src[i * channels];
            chunk[i * 2 + 1] = src[i * channels + (channels > 1 ? 1 : 0)];
        }
        self->ring_.write(chunk, n);
        src += static_cast<size_t>(n) * channels;
        frames -= n;
    }
    return noErr;
}

// RT-SAFE: pulls drift-corrected audio from the ring into the real output.
// The resampler does fixed-size-state Hermite interpolation with a servo on
// the fill level — no locks, no allocation (see Resampler.h).
OSStatus AudioEngine::outputProc(AudioObjectID, const AudioTimeStamp*,
                                 const AudioBufferList*, const AudioTimeStamp*,
                                 AudioBufferList* outputData, const AudioTimeStamp*,
                                 void* clientData) {
    auto* self = static_cast<AudioEngine*>(clientData);
    if (!outputData || outputData->mNumberBuffers == 0) return noErr;

    AudioBuffer& buf = outputData->mBuffers[0];
    auto* dst = static_cast<float*>(buf.mData);
    const uint32_t channels = buf.mNumberChannels;
    if (!dst || channels == 0) return noErr;
    uint32_t frames = buf.mDataByteSize / (channels * sizeof(float));

    if (!self->running_.load(std::memory_order_relaxed)) {
        // HAL pre-zeroes output buffers; leaving them untouched means silence.
        return noErr;
    }

    // First output tick: discard overruns accrued while this device was
    // starting up (RT-safe: two atomics). Keeps the dropout counter honest.
    if (!self->outputTicked_.exchange(true, std::memory_order_relaxed))
        self->ring_.clearOverruns();

    if (channels == 2) {
        self->resampler_.pull(self->ring_, dst, frames);
        self->chain_.processInterleavedStereo(dst, frames);  // RT-SAFE, see PluginChain
        self->outLevel_.store(rmsOf(dst, frames * 2), std::memory_order_relaxed);
        return noErr;
    }
    // Non-stereo output: spread stereo into first two channels, zero the rest.
    float chunk[kChunkFrames * 2];
    while (frames > 0) {
        const uint32_t n = frames < kChunkFrames ? frames : kChunkFrames;
        self->resampler_.pull(self->ring_, chunk, n);
        self->chain_.processInterleavedStereo(chunk, n);
        for (uint32_t i = 0; i < n; ++i) {
            dst[i * channels] = chunk[i * 2];
            if (channels > 1) dst[i * channels + 1] = chunk[i * 2 + 1];
            for (uint32_t c = 2; c < channels; ++c) dst[i * channels + c] = 0.0f;
        }
        dst += static_cast<size_t>(n) * channels;
        frames -= n;
    }
    return noErr;
}

} // namespace fxrouter
