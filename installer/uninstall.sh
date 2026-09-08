#!/bin/bash
# FXRouter Stage-1 local uninstall. Removes the app and HAL driver, and makes
# sure the system default output is NOT left pointing at the (now gone)
# virtual device — the user is never stranded in silence (F1).
#
#   ./uninstall.sh          removes app + driver, keeps settings/presets
#   ./uninstall.sh --purge  also removes catalog, chain, presets, and logs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_DST="/Library/Audio/Plug-Ins/HAL/FXRouter.driver"
APP_DST="/Applications/FXRouter.app"
PURGE="${1:-}"

echo "==> Restoring a real default output if needed"
swift "$REPO_ROOT/installer/restore-output.swift" || true

if pgrep -x FXRouter >/dev/null; then
    echo "==> Quitting FXRouter"
    pkill -x FXRouter || true
    sleep 2
    pkill -9 -x FXRouter 2>/dev/null || true
fi

echo "==> Removing $APP_DST"
rm -rf "$APP_DST"

echo "==> Removing $DRIVER_DST (sudo required)"
sudo rm -rf "$DRIVER_DST"

echo "==> Restarting coreaudiod"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null \
    || sudo killall coreaudiod

if [ "$PURGE" = "--purge" ]; then
    echo "==> Purging user data (catalog, chain, presets, logs)"
    rm -rf "$HOME/Library/Application Support/FXRouter"
    rm -f "$HOME/Library/Logs/FXRouter.log"
    defaults delete com.fxrouter.app 2>/dev/null || true
fi

echo
echo "Done. 'FXRouter' should be gone from System Settings → Sound."
[ "$PURGE" = "--purge" ] || echo "(Settings and presets kept — use --purge to remove them too.)"
