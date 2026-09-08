// FXRouter host engine — plugin chain implementation (JUCE inside).
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#include "PluginChain.h"

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_audio_utils/juce_audio_utils.h>
#include <juce_events/juce_events.h>
#include <juce_gui_basics/juce_gui_basics.h>

#include <atomic>

namespace fxrouter {

namespace {
constexpr uint32_t kMaxBlockCap = 4096;  // hard cap on preallocated block size
using Graph = juce::AudioProcessorGraph;
} // namespace

// A window that hosts a plugin's own editor UI. Closing hides it; the chain
// owns the lifetime and destroys it when the plugin is removed.
class EditorWindow : public juce::DocumentWindow {
public:
    EditorWindow(const juce::String& title, juce::AudioProcessor& processor)
        : juce::DocumentWindow(title, juce::Colours::darkgrey,
                               juce::DocumentWindow::closeButton) {
        setUsingNativeTitleBar(true);
        juce::AudioProcessorEditor* editor = processor.createEditorIfNeeded();
        if (editor == nullptr)
            editor = new juce::GenericAudioProcessorEditor(processor);  // sliders fallback
        setContentOwned(editor, true);
        setResizable(editor->isResizable(), false);
        centreWithSize(getWidth(), getHeight());
    }

    void closeButtonPressed() override { setVisible(false); }
};

struct PluginChain::Impl {
    juce::AudioPluginFormatManager formatManager;
    juce::KnownPluginList knownList;   // main thread only

    Graph graph;
    Graph::Node::Ptr inputNode, outputNode;
    std::vector<Graph::Node::Ptr> slots;                       // ordered chain
    std::vector<std::unique_ptr<EditorWindow>> editors;        // parallel to slots

    // Audio thread state.
    std::atomic<bool> graphReady{false};
    std::atomic<bool> masterBypass{false};
    juce::AudioBuffer<float> deinterleaved{2, kMaxBlockCap};   // preallocated
    juce::MidiBuffer midiScratch;                              // stays empty

    double sampleRate = 0;
    uint32_t maxBlock = 0;
    bool hostingInitialised = false;
    std::string lastError;

    bool rebuildConnections() {
        // Drop every existing connection, then wire input → slots… → output.
        for (const auto& c : graph.getConnections())
            graph.removeConnection(c);

        bool allOk = true;
        Graph::Node::Ptr prev = inputNode;
        for (const auto& node : slots) {
            for (int ch = 0; ch < 2; ++ch)
                allOk &= graph.addConnection({{prev->nodeID, ch}, {node->nodeID, ch}});
            prev = node;
        }
        for (int ch = 0; ch < 2; ++ch)
            allOk &= graph.addConnection({{prev->nodeID, ch}, {outputNode->nodeID, ch}});
        if (!allOk)
            lastError = "graph wiring incomplete (a connection was rejected)";
        return allOk;
    }

    void prepareGraph() {
        if (sampleRate <= 0 || maxBlock == 0) return;
        graphReady = false;
        graph.releaseResources();
        graph.setPlayConfigDetails(2, 2, sampleRate, static_cast<int>(maxBlock));
        graph.prepareToPlay(sampleRate, static_cast<int>(maxBlock));
        // Connections wired before the graph knew its channel layout get
        // rejected as illegal (the launch-with-empty-chain silence bug), so
        // (re)wire once the layout is final.
        rebuildConnections();
        graphReady = true;
    }
};

PluginChain::PluginChain() : impl_(std::make_unique<Impl>()) {}

PluginChain::~PluginChain() {
    impl_->graphReady = false;
    impl_->editors.clear();
    impl_->graph.clear();
    if (impl_->hostingInitialised)
        juce::shutdownJuce_GUI();
}

void PluginChain::initialiseHosting() {
    if (impl_->hostingInitialised) return;
    // Embedding JUCE in an existing AppKit app: events integrate with the
    // main CFRunLoop; no separate JUCE message loop is run.
    juce::initialiseJuce_GUI();
    impl_->formatManager.addDefaultFormats();

    using IO = Graph::AudioGraphIOProcessor;
    impl_->inputNode = impl_->graph.addNode(
        std::make_unique<IO>(IO::audioInputNode));
    impl_->outputNode = impl_->graph.addNode(
        std::make_unique<IO>(IO::audioOutputNode));
    impl_->rebuildConnections();

    impl_->hostingInitialised = true;
}

void PluginChain::setPlayConfig(double sampleRate, uint32_t maxBlockFrames) {
    // Called only while the engine's IOProcs are stopped.
    impl_->sampleRate = sampleRate;
    impl_->maxBlock = maxBlockFrames > kMaxBlockCap ? kMaxBlockCap : maxBlockFrames;
    impl_->prepareGraph();
}

// Every chain mutation runs with graphReady=false: the audio thread falls
// back to clean dry passthrough for the few ms of graph surgery instead of
// risking a stall (the buffer-overfill events seen with heavy plugins), and
// prepareGraph() re-arms processing with connections rebuilt.
bool PluginChain::addPlugin(const std::string& identifier, size_t index) {
    impl_->graphReady = false;
    const bool ok = insertPluginNode(identifier, index);
    impl_->prepareGraph();
    return ok;
}

bool PluginChain::insertPluginNode(const std::string& identifier, size_t index) {
    impl_->lastError.clear();

    juce::PluginDescription desc;
    for (const auto& d : impl_->knownList.getTypes()) {
        if (d.fileOrIdentifier.toStdString() == identifier) {
            desc = d;
            break;
        }
    }
    if (desc.name.isEmpty()) {
        impl_->lastError = "Plugin not found in catalog: " + identifier;
        return false;
    }

    juce::String error;
    auto instance = impl_->formatManager.createPluginInstance(
        desc, impl_->sampleRate > 0 ? impl_->sampleRate : 48000.0,
        impl_->maxBlock > 0 ? static_cast<int>(impl_->maxBlock) : 512, error);
    if (instance == nullptr) {
        impl_->lastError = "Could not load " + desc.name.toStdString() + ": " +
                           error.toStdString();
        return false;
    }

    // Channel-compat rule: the chain is stereo end to end — but only the MAIN
    // buses matter. Plugins with extra sidechain/aux buses (AR-1 etc.) must
    // not be rejected for having them; we negotiate the mains to stereo and
    // leave the rest as the plugin prefers (unconnected buses stay silent).
    const auto stereoSet = juce::AudioChannelSet::stereo();
    bool stereoMains = instance->getBus(true, 0) != nullptr &&
                       instance->getBus(false, 0) != nullptr &&
                       instance->getChannelLayoutOfBus(true, 0) == stereoSet &&
                       instance->getChannelLayoutOfBus(false, 0) == stereoSet;
    if (!stereoMains) {
        // Ask for stereo mains while keeping the plugin's other buses intact.
        auto layout = instance->getBusesLayout();
        if (!layout.inputBuses.isEmpty()) layout.inputBuses.setUnchecked(0, stereoSet);
        if (!layout.outputBuses.isEmpty()) layout.outputBuses.setUnchecked(0, stereoSet);
        stereoMains = instance->setBusesLayout(layout);
    }
    if (!stereoMains) {
        // Last resort: plain one-stereo-in/one-stereo-out.
        juce::AudioProcessor::BusesLayout plain;
        plain.inputBuses.add(stereoSet);
        plain.outputBuses.add(stereoSet);
        stereoMains = instance->setBusesLayout(plain);
    }
    if (!stereoMains) {
        impl_->lastError = desc.name.toStdString() +
                           " could not be configured for stereo in/out; not inserted.";
        return false;
    }

    auto node = impl_->graph.addNode(std::move(instance));
    if (node == nullptr) {
        impl_->lastError = "Graph refused node for " + desc.name.toStdString();
        return false;
    }

    if (index > impl_->slots.size()) index = impl_->slots.size();
    impl_->slots.insert(impl_->slots.begin() + static_cast<long>(index), node);
    impl_->editors.insert(impl_->editors.begin() + static_cast<long>(index), nullptr);
    impl_->rebuildConnections();
    return true;
}

bool PluginChain::removePlugin(size_t index) {
    if (index >= impl_->slots.size()) return false;
    impl_->graphReady = false;
    impl_->editors.erase(impl_->editors.begin() + static_cast<long>(index));
    impl_->graph.removeNode(impl_->slots[index]->nodeID);
    impl_->slots.erase(impl_->slots.begin() + static_cast<long>(index));
    impl_->prepareGraph();
    return true;
}

bool PluginChain::movePlugin(size_t from, size_t to) {
    const size_t n = impl_->slots.size();
    if (from >= n || to >= n || from == to) return false;
    impl_->graphReady = false;
    auto node = impl_->slots[from];
    auto editor = std::move(impl_->editors[from]);
    impl_->slots.erase(impl_->slots.begin() + static_cast<long>(from));
    impl_->editors.erase(impl_->editors.begin() + static_cast<long>(from));
    impl_->slots.insert(impl_->slots.begin() + static_cast<long>(to), node);
    impl_->editors.insert(impl_->editors.begin() + static_cast<long>(to), std::move(editor));
    impl_->prepareGraph();
    return true;
}

void PluginChain::clearChain() {
    impl_->graphReady = false;
    impl_->editors.clear();
    for (auto& node : impl_->slots)
        impl_->graph.removeNode(node->nodeID);
    impl_->slots.clear();
    impl_->prepareGraph();
}

void PluginChain::setSlotBypassed(size_t index, bool bypassed) {
    if (index >= impl_->slots.size()) return;
    impl_->slots[index]->setBypassed(bypassed);
}

void PluginChain::setMasterBypass(bool bypassed) {
    impl_->masterBypass.store(bypassed, std::memory_order_release);
}

bool PluginChain::masterBypass() const {
    return impl_->masterBypass.load(std::memory_order_relaxed);
}

std::vector<ChainSlot> PluginChain::chain() const {
    std::vector<ChainSlot> result;
    for (const auto& node : impl_->slots) {
        ChainSlot slot;
        if (auto* proc = node->getProcessor()) {
            slot.name = proc->getName().toStdString();
            if (auto* inst = dynamic_cast<juce::AudioPluginInstance*>(proc))
                slot.format = inst->getPluginDescription().pluginFormatName.toStdString();
        }
        slot.bypassed = node->isBypassed();
        result.push_back(std::move(slot));
    }
    return result;
}

bool PluginChain::openEditor(size_t index) {
    if (index >= impl_->slots.size()) return false;
    auto& windowSlot = impl_->editors[index];
    if (windowSlot == nullptr) {
        auto* proc = impl_->slots[index]->getProcessor();
        if (proc == nullptr) return false;
        windowSlot = std::make_unique<EditorWindow>(proc->getName(), *proc);
    }
    windowSlot->setVisible(true);
    windowSlot->toFront(true);
    return true;
}

const std::string& PluginChain::lastError() const {
    return impl_->lastError;
}

bool PluginChain::saveChainToFile(const std::string& xmlPath) {
    juce::XmlElement root("FXROUTER_CHAIN");
    root.setAttribute("masterBypass", impl_->masterBypass.load() ? 1 : 0);
    for (const auto& node : impl_->slots) {
        auto* proc = dynamic_cast<juce::AudioPluginInstance*>(node->getProcessor());
        if (proc == nullptr) continue;
        auto* slot = root.createNewChildElement("SLOT");
        slot->setAttribute("identifier",
                           proc->getPluginDescription().fileOrIdentifier);
        slot->setAttribute("bypassed", node->isBypassed() ? 1 : 0);
        juce::MemoryBlock state;
        proc->getStateInformation(state);
        slot->setAttribute("state", state.toBase64Encoding());
    }
    const juce::File file{juce::String(xmlPath)};
    file.getParentDirectory().createDirectory();
    return root.writeTo(file);
}

size_t PluginChain::restoreChainFromFile(const std::string& xmlPath) {
    const juce::File file{juce::String(xmlPath)};
    if (!file.existsAsFile()) return 0;
    const auto xml = juce::XmlDocument::parse(file);
    if (xml == nullptr || !xml->hasTagName("FXROUTER_CHAIN")) return 0;

    setMasterBypass(xml->getIntAttribute("masterBypass") != 0);

    // Bulk edit: one graph re-preparation at the end; audio stays in dry
    // passthrough while the (potentially heavy) plugins instantiate.
    impl_->graphReady = false;
    size_t restored = 0;
    for (auto* slot : xml->getChildIterator()) {
        if (!slot->hasTagName("SLOT")) continue;
        const std::string identifier = slot->getStringAttribute("identifier").toStdString();
        if (!insertPluginNode(identifier, impl_->slots.size()))
            continue;  // plugin gone/unloadable — skip, keep the rest
        const size_t index = impl_->slots.size() - 1;
        juce::MemoryBlock state;
        if (state.fromBase64Encoding(slot->getStringAttribute("state")) &&
            state.getSize() > 0) {
            if (auto* proc = impl_->slots[index]->getProcessor())
                proc->setStateInformation(state.getData(),
                                          static_cast<int>(state.getSize()));
        }
        setSlotBypassed(index, slot->getIntAttribute("bypassed") != 0);
        ++restored;
    }
    impl_->prepareGraph();
    return restored;
}

bool PluginChain::loadCatalogFromFile(const std::string& xmlPath) {
    const juce::File file{juce::String(xmlPath)};
    if (!file.existsAsFile()) return false;
    const auto xml = juce::XmlDocument::parse(file);
    if (xml == nullptr) return false;
    impl_->knownList.recreateFromXml(*xml);
    return true;
}

std::vector<PluginListing> PluginChain::catalog() const {
    std::vector<PluginListing> result;
    for (const auto& d : impl_->knownList.getTypes()) {
        PluginListing entry;
        entry.name = d.name.toStdString();
        entry.format = d.pluginFormatName.toStdString();
        entry.manufacturer = d.manufacturerName.toStdString();
        entry.identifier = d.fileOrIdentifier.toStdString();
        entry.isInstrument = d.isInstrument;
        entry.numInputChannels = d.numInputChannels;
        entry.numOutputChannels = d.numOutputChannels;
        result.push_back(std::move(entry));
    }
    return result;
}

// RT-SAFE: atomic gates, then deinterleave into the preallocated buffer
// (JUCE processors take non-interleaved channels), run the graph, and
// re-interleave. The graph's own render sequence handles node changes made on
// the message thread without blocking this one.
void PluginChain::processInterleavedStereo(float* interleaved, uint32_t frames) {
    if (!impl_->graphReady.load(std::memory_order_acquire)) return;
    if (impl_->masterBypass.load(std::memory_order_relaxed)) return;

    uint32_t offset = 0;
    while (offset < frames) {
        const uint32_t n = std::min(frames - offset, impl_->maxBlock);
        float* L = impl_->deinterleaved.getWritePointer(0);
        float* R = impl_->deinterleaved.getWritePointer(1);
        const float* src = interleaved + offset * 2;
        for (uint32_t i = 0; i < n; ++i) {
            L[i] = src[i * 2];
            R[i] = src[i * 2 + 1];
        }
        juce::AudioBuffer<float> block(impl_->deinterleaved.getArrayOfWritePointers(),
                                       2, 0, static_cast<int>(n));
        impl_->midiScratch.clear();
        impl_->graph.processBlock(block, impl_->midiScratch);

        float* dst = interleaved + offset * 2;
        for (uint32_t i = 0; i < n; ++i) {
            dst[i * 2]     = L[i];
            dst[i * 2 + 1] = R[i];
        }
        offset += n;
    }
}

// ---------------------------------------------------------------------------
// Out-of-process scan worker (runs in a separate, disposable process).

int runPluginScanWorker(const std::string& resultPath,
                        const std::string& deadmanPath,
                        const std::string& blacklistPath) {
    juce::initialiseJuce_GUI();

    juce::StringArray blacklist;
    {
        const juce::File blFile{juce::String(blacklistPath)};
        if (blFile.existsAsFile())
            blFile.readLines(blacklist);
    }
    const juce::File deadman{juce::String(deadmanPath)};
    const char* crashOn = ::getenv("FXROUTER_SCAN_CRASH_ON");  // test hook

    juce::AudioPluginFormatManager manager;
    manager.addDefaultFormats();
    juce::KnownPluginList list;

    for (auto* format : manager.getFormats()) {
        const juce::String formatName = format->getName();
        if (formatName != "AudioUnit" && formatName != "VST3")
            continue;
        const auto identifiers = format->searchPathsForPlugins(
            format->getDefaultLocationsToSearch(), /*recursive*/ true,
            /*allowPluginsWhichRequireAsynchronousInstantiation*/ false);

        for (const auto& ident : identifiers) {
            if (blacklist.contains(ident)) continue;

            // Dead-man's switch: if probing this plugin kills us, the parent
            // reads this file, blacklists the identifier, and relaunches.
            deadman.replaceWithText(ident);

            if (crashOn != nullptr && ident.contains(crashOn))
                ::abort();  // simulated crashing plugin (test hook)

            juce::OwnedArray<juce::PluginDescription> found;
            list.scanAndAddFile(ident, /*dontRescanIfAlreadyInList*/ true,
                                found, *format);
            deadman.replaceWithText({});
        }
    }

    if (const auto xml = list.createXml()) {
        const juce::File result{juce::String(resultPath)};
        result.getParentDirectory().createDirectory();
        if (!xml->writeTo(result)) {
            juce::shutdownJuce_GUI();
            return 2;
        }
    }
    juce::shutdownJuce_GUI();
    return 0;
}

} // namespace fxrouter
