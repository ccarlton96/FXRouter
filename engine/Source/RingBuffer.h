// FXRouter host engine — lock-free SPSC ring buffer for stereo float frames.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// Transport between the input IOProc (producer) and output IOProc (consumer).
// Phase 3: consumption goes through AdaptiveResampler (Resampler.h), which
// servo-controls its rate off the fill level so clock drift never reaches the
// under/overrun point. The ring itself just moves frames.
//
// RT-SAFE: single producer / single consumer. No locks, no allocation after
// construction, acq-rel atomics only.

#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace fxrouter {

class StereoRingBuffer {
public:
    explicit StereoRingBuffer(uint32_t capacityFrames = 16384) {
        capacity_ = 1;
        while (capacity_ < capacityFrames) capacity_ <<= 1;
        storage_.resize(static_cast<size_t>(capacity_) * 2, 0.0f);  // alloc off-thread, in ctor
    }

    // RT-SAFE (producer). Interleaved stereo. Frames that don't fit are
    // dropped (newest lost) and counted as an overrun.
    void write(const float* interleaved, uint32_t frames) {
        const uint64_t w = writePos_.load(std::memory_order_relaxed);
        const uint64_t r = readPos_.load(std::memory_order_acquire);
        const uint32_t free = capacity_ - static_cast<uint32_t>(w - r);
        uint32_t toWrite = frames;
        if (toWrite > free) {
            toWrite = free;
            overruns_.fetch_add(1, std::memory_order_relaxed);
        }
        for (uint32_t i = 0; i < toWrite; ++i) {
            const uint32_t idx = static_cast<uint32_t>((w + i) & (capacity_ - 1));
            storage_[idx * 2]     = interleaved[i * 2];
            storage_[idx * 2 + 1] = interleaved[i * 2 + 1];
        }
        writePos_.store(w + toWrite, std::memory_order_release);
    }

    // RT-SAFE (consumer). Batches the consumer's atomic traffic: one acquire
    // at begin(), one release store of readPos at end() — frame pops in
    // between are plain loads.
    class ConsumerView {
    public:
        explicit ConsumerView(StereoRingBuffer& ring)
            : ring_(ring),
              write_(ring.writePos_.load(std::memory_order_acquire)),
              read_(ring.readPos_.load(std::memory_order_relaxed)) {}

        ~ConsumerView() { ring_.readPos_.store(read_, std::memory_order_release); }

        uint32_t available() const { return static_cast<uint32_t>(write_ - read_); }

        // Advances the read cursor without copying (backlog hard-resync).
        void skip(uint32_t frames) {
            const uint64_t avail = write_ - read_;
            read_ += frames < avail ? frames : avail;
        }

        // False (and outputs untouched) if empty.
        bool pop(float& left, float& right) {
            if (read_ == write_) return false;
            const uint32_t idx = static_cast<uint32_t>(read_ & (ring_.capacity_ - 1));
            left  = ring_.storage_[idx * 2];
            right = ring_.storage_[idx * 2 + 1];
            ++read_;
            return true;
        }

    private:
        StereoRingBuffer& ring_;
        const uint64_t write_;
        uint64_t read_;
    };

    uint32_t fillFrames() const {
        return static_cast<uint32_t>(writePos_.load(std::memory_order_acquire) -
                                     readPos_.load(std::memory_order_acquire));
    }

    uint32_t capacity() const { return capacity_; }
    uint64_t overruns() const { return overruns_.load(std::memory_order_relaxed); }

    // RT-SAFE. Discards overruns accrued while the output device was still
    // spinning up — they're launch transients, not audible dropouts.
    void clearOverruns() { overruns_.store(0, std::memory_order_relaxed); }

    void reset() {  // NOT RT-safe; call only while both IOProcs are stopped
        writePos_.store(0);
        readPos_.store(0);
        overruns_.store(0);
        std::fill(storage_.begin(), storage_.end(), 0.0f);
    }

private:
    std::vector<float> storage_;
    uint32_t capacity_ = 0;
    std::atomic<uint64_t> writePos_{0};
    std::atomic<uint64_t> readPos_{0};
    std::atomic<uint64_t> overruns_{0};
};

} // namespace fxrouter
