#!/bin/bash
# Builds SezgiViewer as a release .app bundle for Apple Silicon (arm64).
# The result is placed in ./build/Release/SezgiViewer.app
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-Release}"

xcodebuild \
  -project SezgiViewer.xcodeproj \
  -scheme SezgiViewer \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  SYMROOT=build \
  build

APP="build/$CONFIG/SezgiViewer.app"
echo ""
echo "Built: $APP"
echo "Run with:  open \"$APP\""
echo "Install:   cp -R \"$APP\" /Applications/"
