#!/bin/bash
# Builds PhotoCurator.app: compiles the SwiftPM executable, wraps it in a proper
# .app bundle with Info.plist, and ad-hoc codesigns it with the App Sandbox
# entitlements in Resources/PhotoCurator.entitlements.
#
# No Xcode project and no paid Apple Developer account needed — ad-hoc signing
# (`codesign --sign -`) is enough to run a sandboxed app locally (spec §9); a paid
# membership is only required to notarize/distribute via Developer ID or the App
# Store. `open Package.swift` in Xcode also works directly for day-to-day
# development, but won't apply these entitlements — use this script (or
# `swift run`, unsandboxed) to exercise the real App Sandbox / bookmark path.
#
# Usage: Scripts/build_app.sh [debug|release]
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="PhotoCurator"
OUTPUT_DIR=".build/app"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

if [ "$CONFIGURATION" = "release" ]; then
    BUILD_FLAGS=(-c release)
    EXECUTABLE_PATH=".build/release/${APP_NAME}"
else
    BUILD_FLAGS=()
    EXECUTABLE_PATH=".build/debug/${APP_NAME}"
fi

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
# The `+` form guards against macOS's bash 3.2 treating an empty array expansion as
# an unbound variable under `set -u`.
swift build "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}"

echo "==> Assembling app bundle at ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${EXECUTABLE_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Code signing (ad-hoc) with App Sandbox entitlements"
codesign --force \
    --sign - \
    --entitlements "Resources/PhotoCurator.entitlements" \
    "${APP_BUNDLE}"

echo "==> Verifying signature and entitlements"
codesign --verify --strict "${APP_BUNDLE}"
codesign -d --entitlements - "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo "    Run with: open \"${APP_BUNDLE}\""
