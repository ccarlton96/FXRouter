// FXRouter host engine — adaptive resampler (drift compensation).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// The consumer pulls frames through a 4-point Hermite interpolator whose
// ratio is servo-controlled by the ring's fill level. The virtual device's
// clock and the real output's clock drift by ~±100 ppm; the servo absorbs
// that continuously so the ring never reaches under/overrun in steady
// state. Correction is capped at ±kMaxCorrection (2000 ppm) — far below
// audibility for pitch (≈3.5 cents).
//
// RT-SAFE (consumer side only): fixed-size state, no allocation, no locks.
// Status values published through relaxed atomics for the UI thread to read.

#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "RingBuffer.h"

namespace fxrouter {

class AdaptiveResampler {
public:
    // targetFillFrames: the fill level the servo holds (also the prime level).
    void configure(uint32_t targetFillFrames) {  // NOT RT-safe; call while stopped
        targetFill_ = std::max(targetFillFrames, 256u);
        reset();
    }

    void reset() {  // NOT RT-safe; call while stopped
        primed_ = false;
        phase_ = 0.0;
        ratio_ = 1.0;
        smoothedFill_ = 0.0;
        std::memset(histL_, 0, sizeof(histL_));
        std::memset(histR_, 0, sizeof(histR_));
        underruns_.store(0);
        ratioPPM_.store(0);
        fillNow_.store(0);
    }

    // RT-SAFE. Produces `frames` interleaved stereo output frames from the
    // ring; zero-fills while priming or on underrun.
    void pull(StereoRingBuffer& ring, float* out, uint32_t frames) {
        StereoRingBuffer::ConsumerView view(ring);
        uint32_t avail = view.available();

        // Backlog hard-resync: a gross overfill (e.g. the producer ran while
        // the consumer was stalled by heavy plugin loading) would take the
        // ±2000ppm servo minutes to drain, leaving audible extra latency the
        // whole time. One clean jump back to target is better.
        if (avail > targetFill_ * 4) {
            view.skip(avail - targetFill_);
            avail = view.available();
            smoothedFill_ = static_cast<double>(avail);
            resyncs_.fetch_add(1, std::memory_order_relaxed);
        }
        fillNow_.store(avail, std::memory_order_relaxed);

        if (!primed_) {
            if (avail < targetFill_) {  // still building the cushion
                std::memset(out, 0, sizeof(float) * 2 * frames);
                return;
            }
            // Seed the interpolation history from the stream.
            for (int i = 0; i < 4; ++i) view.pop(histL_[i], histR_[i]);
            phase_ = 0.0;
            smoothedFill_ = static_cast<double>(avail);
            primed_ = true;
        }

        // Servo: exponential smoothing of the fill level, then a proportional
        // nudge of the ratio. Positive error (too full) => ratio > 1 =>
        // consume faster. Time constant ~0.5 s at 256-frame callbacks.
        smoothedFill_ += kFillAlpha * (static_cast<double>(avail) - smoothedFill_);
        const double error = (smoothedFill_ - static_cast<double>(targetFill_)) /
                             static_cast<double>(targetFill_);
        ratio_ = 1.0 + std::clamp(error, -1.0, 1.0) * kMaxCorrection;
        ratioPPM_.store(static_cast<int32_t>((ratio_ - 1.0) * 1e6),
                        std::memory_order_relaxed);

        for (uint32_t i = 0; i < frames; ++i) {
            // Advance the source cursor; pull new frames into history as the
            // integer part of the phase crosses frame boundaries.
            while (phase_ >= 1.0) {
                float l, r;
                if (!view.pop(l, r)) {
                    // Drift shouldn't get us here in steady state — this is a
                    // genuine dropout (system overload etc.). Rebuild cushion.
                    underruns_.fetch_add(1, std::memory_order_relaxed);
                    primed_ = false;
                    std::memset(out + i * 2, 0, sizeof(float) * 2 * (frames - i));
                    return;
                }
                histL_[0] = histL_[1]; histL_[1] = histL_[2]; histL_[2] = histL_[3]; histL_[3] = l;
                histR_[0] = histR_[1]; histR_[1] = histR_[2]; histR_[2] = histR_[3]; histR_[3] = r;
                phase_ -= 1.0;
            }
            const float t = static_cast<float>(phase_);
            out[i * 2]     = hermite(histL_, t);
            out[i * 2 + 1] = hermite(histR_, t);
            phase_ += ratio_;
        }
    }

    uint64_t underruns() const { return underruns_.load(std::memory_order_relaxed); }
    uint64_t resyncs() const { return resyncs_.load(std::memory_order_relaxed); }
    int32_t ratioPPM() const { return ratioPPM_.load(std::memory_order_relaxed); }
    uint32_t fillFrames() const { return fillNow_.load(std::memory_order_relaxed); }
    uint32_t targetFill() const { return targetFill_; }

private:
    // 4-point, 3rd-order Hermite (Catmull-Rom): interpolates between h[1] and
    // h[2] at fraction t. Inaudible artifacts at near-unity ratios.
    static float hermite(const float h[4], float t) {
        const float c1 = 0.5f * (h[2] - h[0]);
        const float c2 = h[0] - 2.5f * h[1] + 2.0f * h[2] - 0.5f * h[3];
        const float c3 = 0.5f * (h[3] - h[0]) + 1.5f * (h[1] - h[2]);
        return ((c3 * t + c2) * t + c1) * t + h[1];
    }

    static constexpr double kFillAlpha = 0.02;      // fill EMA per callback
    static constexpr double kMaxCorrection = 0.002; // ±2000 ppm ratio authority

    uint32_t targetFill_ = 1024;
    bool primed_ = false;
    double phase_ = 0.0;
    double ratio_ = 1.0;
    double smoothedFill_ = 0.0;
    float histL_[4] = {};
    float histR_[4] = {};

    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> resyncs_{0};
    std::atomic<int32_t> ratioPPM_{0};
    std::atomic<uint32_t> fillNow_{0};
};

} // namespace fxrouter
