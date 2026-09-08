#!/bin/bash
# Builds a distributable FXRouter DMG: the classic "drag the icon into
# Applications" installer. Output: dist/FXRouter-<version>.dmg
#
# The app is self-contained — the HAL driver ships inside the app bundle and
# the app offers to install it (admin prompt) on first launch, so the DMG
# alone is a complete installer. See app/FXRouter/DriverInstaller.swift.
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STAGE 1 vs STAGE 2                                                      │
# │                                                                         │
# │ This script currently produces an AD-HOC signed DMG. It works on THIS   │
# │ machine and for anyone who builds from source, but a downloaded copy    │
# │ will be blocked by Gatekeeper on other Macs ("unidentified developer"). │
# │                                                                         │
# │ Public distribution requires Stage 2 (paid Apple Developer Program):    │
# │ the three STAGE-2 blocks below are commented out and marked. Filling    │
# │ in DEVELOPER_ID + a notarytool keychain profile is ALL that's needed —  │
# │ no code changes.                                                        │
# └─────────────────────────────────────────────────────────────────────────┘
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/app/build/Build/Products/Debug/FXRouter.app"
DIST="$REPO_ROOT/dist"
STAGING="$DIST/dmg-staging"

# Single source of truth for the version is the app's project spec.
VERSION="$(grep 'CFBundleShortVersionString:' "$REPO_ROOT/app/project.yml" | awk '{print $2}')"
DMG="$DIST/FXRouter-${VERSION}.dmg"

# --- STAGE 2 (uncomment + fill in when the Developer Program is active) ----
# DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
# NOTARY_PROFILE="fxrouter-notary"   # set up once with:
#   xcrun notarytool store-credentials fxrouter-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
# ---------------------------------------------------------------------------

echo "==> Building all components"
export PATH="/opt/homebrew/bin:$PATH"
"$REPO_ROOT/build.sh"

# --- STAGE 2: sign everything with the Developer ID -------------------------
# The driver inside the app must be signed first (inside-out signing), then
# the app with hardened runtime. NOTE: hardened runtime + microphone access
# requires the com.apple.security.device.audio-input entitlement — add an
# entitlements file to app/project.yml when enabling this.
# codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
#     "$APP/Contents/Resources/FXRouter.driver"
# codesign --force --options runtime --timestamp --deep --sign "$DEVELOPER_ID" \
#     "$APP"
# ---------------------------------------------------------------------------

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# The drag-target: a symlink to /Applications right next to the app icon.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
mkdir -p "$DIST"
hdiutil create -volname "FXRouter $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGING"

# --- STAGE 2: notarize + staple so Gatekeeper trusts downloads --------------
# xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
# xcrun stapler staple "$DMG"
# ---------------------------------------------------------------------------

echo "==> Done: $DMG"
echo
echo "Stage 1 note: this DMG works locally and for source-builders. For"
echo "public downloads, activate the STAGE-2 blocks in this script first."
