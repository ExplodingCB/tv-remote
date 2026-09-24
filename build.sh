#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "TV Remote.app" into ./build.
# Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/TVRemote"

APP="build/TV Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TVRemote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/atv_bridge.py "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: there's no paid Apple Developer account behind this app.
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/TV Remote.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/TV Remote.app"
fi
