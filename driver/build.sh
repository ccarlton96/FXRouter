#!/bin/bash
# Builds FXRouter.driver — the HAL AudioServerPlugin (virtual loopback device).
# Output: driver/build/FXRouter.driver, ad-hoc signed (Stage 1, local-only).
# Install is separate: installer/install.sh (needs sudo).
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="build"
BUNDLE="$BUILD_DIR/FXRouter.driver"
MIN_MACOS="13.0"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "==> Compiling FXRouter.c"
clang \
    -bundle \
    -o "$BUNDLE/Contents/MacOS/FXRouter" \
    FXRouter.c \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework Accelerate \
    -mmacosx-version-min="$MIN_MACOS" \
    -O2 \
    -Wall

cp Info.plist "$BUNDLE/Contents/Info.plist"

# Device icon (shows next to "FXRouter" in Sound settings). Generated from
# the user's artwork into the app resources; reused here as kPlugIn_Icon.
APP_ICNS="../app/FXRouter/Resources/AppIcon.icns"
if [ -f "$APP_ICNS" ]; then
    cp "$APP_ICNS" "$BUNDLE/Contents/Resources/FXRouter.icns"
fi

echo "==> Ad-hoc signing (Stage 1 local-only; no Developer ID)"
codesign --sign - --force --deep "$BUNDLE"

echo "==> Built: driver/$BUNDLE"
