// FXRouter host engine — plugin chain interface (JUCE-free header).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.
//
// Phase 6: an ordered chain of hosted plugins between the engine's input and
// output, backed by juce::AudioProcessorGraph (latency compensation + RT-safe
// edit swaps). All mutating calls are
// MAIN THREAD only; the audio thread touches only processInterleavedStereo.
// JUCE is entirely encapsulated in PluginChain.cpp.

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace fxrouter {

// One catalog entry, JUCE-free for the bridge.
struct PluginListing {
    std::string name;
    std::string format;        // "AudioUnit" / "VST3"
    std::string manufacturer;
    std::string identifier;    // JUCE fileOrIdentifier
    bool isInstrument = false;
    int numInputChannels = 0;  // as reported by the scan (0 = unknown)
    int numOutputChannels = 0;
};

// One loaded chain slot.
struct ChainSlot {
    std::string name;
    std::string format;
    bool bypassed = false;
};

// Worker-process entry point (Phase 5, out-of-process scanning).
// Scans AU + VST3, skipping
// identifiers listed in blacklistPath (one per line). Writes the identifier
// being probed to deadmanPath before each attempt (so a crash names its
// culprit) and clears it on success. Writes the final catalog XML to
// resultPath. Returns a process exit code. Runs on the worker's main thread.
// Test hook: if env FXROUTER_SCAN_CRASH_ON is set and an identifier contains
// its value, the worker calls abort() to simulate a crashing plugin.
int runPluginScanWorker(const std::string& resultPath,
                        const std::string& deadmanPath,
                        const std::string& blacklistPath);

class PluginChain {
public:
    PluginChain();
    ~PluginChain();

    PluginChain(const PluginChain&) = delete;
    PluginChain& operator=(const PluginChain&) = delete;

    // One-time JUCE runtime init. MAIN THREAD only, before any other call.
    void initialiseHosting();

    // Tells the chain the stream format. Called from AudioEngine::start()
    // while IOProcs are stopped; re-prepares the graph and all loaded plugins.
    void setPlayConfig(double sampleRate, uint32_t maxBlockFrames);

    // --- Chain management (MAIN THREAD only) -------------------------------
    // Instantiates the catalog plugin with this identifier and inserts it at
    // `index` (clamped to chain size). Rejects plugins that can't run stereo
    // in/out.
    bool addPlugin(const std::string& identifier, size_t index);
    bool removePlugin(size_t index);
    bool movePlugin(size_t from, size_t to);
    // Removes every slot in one graph edit (Reset Default / preset load).
    void clearChain();
    void setSlotBypassed(size_t index, bool bypassed);
    void setMasterBypass(bool bypassed);
    bool masterBypass() const;
    std::vector<ChainSlot> chain() const;

    // Opens (or fronts) the plugin's own editor window. MAIN THREAD only.
    bool openEditor(size_t index);

    const std::string& lastError() const;

    // Chain persistence (Phase 7). MAIN THREAD only. Saves slot order,
    // bypass flags, master bypass, and each plugin's own state blob
    // (getStateInformation) to XML; restore re-instantiates from the catalog.
    bool saveChainToFile(const std::string& xmlPath);
    // Returns number of slots restored (skips plugins that fail to load).
    size_t restoreChainFromFile(const std::string& xmlPath);

    // Catalog (Phase 5). MAIN THREAD only.
    bool loadCatalogFromFile(const std::string& xmlPath);
    std::vector<PluginListing> catalog() const;

    // RT-SAFE: processes interleaved stereo in place through the graph.
    // Straight passthrough when the chain is empty or master-bypassed.
    void processInterleavedStereo(float* interleaved, uint32_t frames);

private:
    bool insertPluginNode(const std::string& identifier, size_t index);

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace fxrouter
