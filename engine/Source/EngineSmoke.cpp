// Phase 0 smoke test: the engine library links and its stub API behaves.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#include "AudioEngine.h"
#include <cstdio>

int main() {
    fxrouter::AudioEngine engine;
    if (engine.isRunning()) {
        std::fprintf(stderr, "FAIL: engine claims to run before start()\n");
        return 1;
    }
    std::printf("engine_smoke OK\n");
    return 0;
}
