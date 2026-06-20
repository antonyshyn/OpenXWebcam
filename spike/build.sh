#!/bin/bash
# Build the Phase 0 spike into a signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="OpenXWebcamSpike"
BUILD="build"
BUNDLE="$BUILD/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"

rm -rf "$BUNDLE"
mkdir -p "$MACOS"

echo "Compiling $APP ..."
xcrun swiftc \
	-swift-version 5 \
	-target arm64-apple-macos12.0 \
	-framework ImageCaptureCore -framework AppKit -framework Foundation \
	-o "$MACOS/$APP" \
	main.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Ad-hoc signing…"
codesign --force --sign - "$BUNDLE"

echo "Built: $BUNDLE"
