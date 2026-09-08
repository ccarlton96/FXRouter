cmake_minimum_required(VERSION 3.24)

project(FXRouterEngine
    VERSION 0.1.0
    DESCRIPTION "FXRouter host engine — plugin hosting and real-time audio processing"
    LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

# ---- JUCE 8 (AGPLv3 option; see THIRD-PARTY-LICENSES.md) -------------------
# Fetched at configure time; first run downloads ~50 MB (shallow).
include(FetchContent)
FetchContent_Declare(JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG        8.0.4
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(JUCE)

add_library(fxrouter_engine STATIC
    Source/AudioEngine.cpp
    Source/PluginChain.cpp
    Source/DeviceIO.cpp
)

target_include_directories(fxrouter_engine PUBLIC Source)

target_compile_definitions(fxrouter_engine
    PRIVATE
        # Hosting formats (04-host-engine.md): AU + VST3. The VST3 SDK ships
        # inside JUCE under its GPLv3 option — see THIRD-PARTY-LICENSES.md.
        JUCE_PLUGINHOST_AU=1
        JUCE_PLUGINHOST_VST3=1
        JUCE_PLUGINHOST_LADSPA=0
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
    PUBLIC
        JUCE_STANDALONE_APPLICATION=0
)

target_link_libraries(fxrouter_engine
    PRIVATE
        juce::juce_audio_processors
        juce::juce_audio_utils
        juce::juce_recommended_config_flags
    PUBLIC
        "-framework CoreAudio"
        "-framework CoreFoundation"
)

# Small smoke-test binary so `ctest`/CI has something to run.
add_executable(engine_smoke Source/EngineSmoke.cpp)
target_link_libraries(engine_smoke PRIVATE fxrouter_engine)

enable_testing()
add_test(NAME engine_smoke COMMAND engine_smoke)
