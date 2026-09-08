#!/bin/bash
# FXRouter Stage-1 local install.
# Ad-hoc signed, local-only. NO Developer ID, NO notarization — that is Stage 2.
# Run this yourself: it needs sudo for the HAL driver path.
#
# What it does:
#   1. Builds driver + engine + app (./build.sh)
#   2. Installs the driver to /Library/Audio/Plug-Ins/HAL (sudo)
#   3. Restarts coreaudiod ONLY if the driver actually changed
#   4. Installs the app to /Applications and launches it
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_SRC="$REPO_ROOT/driver/build/FXRouter.driver"
DRIVER_DST="$HAL_DIR/FXRouter.driver"
APP_SRC="$REPO_ROOT/app/build/Build/Products/Debug/FXRouter.app"
APP_DST="/Applications/FXRouter.app"

echo "==> Preflight"
command -v xcodebuild >/dev/null || { echo "ERROR: Xcode required"; exit 1; }
MISSING=()
command -v cmake >/dev/null || command -v /opt/homebrew/bin/cmake >/dev/null || MISSING+=(cmake)
command -v xcodegen >/dev/null || command -v /opt/homebrew/bin/xcodegen >/dev/null || MISSING+=(xcodegen)
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: missing build tools: ${MISSING[*]}"
    echo "       brew install ${MISSING[*]}"
    exit 1
fi
export PATH="/opt/homebrew/bin:$PATH"

echo "==> Building all components"
"$REPO_ROOT/build.sh"

echo "==> Installing driver"
if [ -d "$DRIVER_DST" ] && diff -rq "$DRIVER_SRC" "$DRIVER_DST" >/dev/null 2>&1; then
    echo "    driver unchanged — skipping (no coreaudiod restart needed)"
else
    echo "    copying to $DRIVER_DST (sudo required)"
    sudo rm -rf "$DRIVER_DST"
    sudo cp -R "$DRIVER_SRC" "$DRIVER_DST"
    sudo chown -R root:wheel "$DRIVER_DST"
    echo "    restarting coreaudiod (audio will blip for a second)"
    # SIP blocks `launchctl kickstart` for coreaudiod on newer macOS;
    # killall works — launchd respawns it immediately.
    sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null \
        || sudo killall coreaudiod
fi

echo "==> Installing app to $APP_DST"
if pgrep -x FXRouter >/dev/null; then
    echo "    quitting running FXRouter"
    pkill -x FXRouter || true
    sleep 2
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Launching FXRouter"
open "$APP_DST"

cat <<'EOF'

Done. FXRouter is installed and running from /Applications.

  * "FXRouter" should be selected in System Settings → Sound → Output for
    audio to flow through your effect chain.
  * If the FXRouter device is missing: check System Settings →
    Privacy & Security for an "Allow" prompt about the driver (one-time,
    local approval for ad-hoc drivers on Apple Silicon), approve it, then:
      sudo killall coreaudiod
  * If you had "Launch at Login" enabled from a development build, toggle
    it off/on once in FX menu → Settings so it points at /Applications.
EOF
