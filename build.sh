#!/bin/bash
# Builds all three FXRouter components (Phase 0 gate: one command builds everything).
#   driver — clang build script (no extra tools needed)
#   engine — CMake
#   app    — XcodeGen + xcodebuild
set -euo pipefail
cd "$(dirname "$0")"

FAILED=()

echo "════ 1/3 driver ════"
./driver/build.sh

echo "════ 2/3 engine ════"
if command -v cmake >/dev/null 2>&1; then
    cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
    cmake --build engine/build
    ctest --test-dir engine/build --output-on-failure
else
    echo "SKIPPED: cmake not installed (brew install cmake)"
    FAILED+=(engine)
fi

echo "════ 3/3 app ════"
if command -v xcodegen >/dev/null 2>&1; then
    (cd app && xcodegen generate)
    xcodebuild -project app/FXRouter.xcodeproj -scheme FXRouter -configuration Debug \
        -derivedDataPath app/build -quiet build
    echo "App built: app/build/Build/Products/Debug/FXRouter.app"
else
    echo "SKIPPED: xcodegen not installed (brew install xcodegen)"
    FAILED+=(app)
fi

echo
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "⚠ Incomplete build — skipped: ${FAILED[*]}"
    exit 1
fi
echo "✓ All three components built."
