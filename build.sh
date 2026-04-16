#!/bin/bash
# Build Claude Usage and install to /Applications.
#
# Usage:
#   ./build.sh               — incremental Debug build + install
#   ./build.sh Release       — incremental Release build + install
#   ./build.sh --clean       — clean Debug build + install
#   ./build.sh Release --clean — clean Release build + install
set -e

CONFIG=Debug
CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=true ;;
    Debug|Release) CONFIG="$arg" ;;
  esac
done

if $CLEAN; then
  echo "Cleaning DerivedData for Claude Usage..."
  xcodebuild \
    -project "Claude Usage.xcodeproj" \
    -scheme "Claude Usage" \
    -configuration "$CONFIG" \
    clean
fi

xcodebuild \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration "$CONFIG" \
  -destination "platform=macOS" \
  build

BUILD_DIR=$(xcodebuild \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | grep '^\s*BUILT_PRODUCTS_DIR' \
  | head -1 \
  | sed 's/.*= //')

APP="$BUILD_DIR/Claude Usage.app"

if [ ! -d "$APP" ]; then
  echo "ERROR: Built app not found at $APP"
  exit 1
fi

echo "Installing to /Applications..."
# Quit the running app first so the copy doesn't race with the running process
osascript -e 'quit app "Claude Usage"' 2>/dev/null || true
sleep 1
cp -R "$APP" /Applications/

# Safety guards before removing DerivedData artifact:
#  1. Path must be non-empty
#  2. Must live inside Xcode's DerivedData (never a system or user dir)
#  3. Must end in .app
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -z "$APP" ]]; then
  echo "WARNING: APP path is empty — skipping DerivedData cleanup"
elif [[ "$APP" != "$DERIVED_DATA"* ]]; then
  echo "WARNING: '$APP' is not inside DerivedData — skipping cleanup"
elif [[ "$APP" != *.app ]]; then
  echo "WARNING: '$APP' does not end in .app — skipping cleanup"
else
  rm -rf "$APP"
  echo "Removed DerivedData artifact."
fi

echo "Launching Claude Usage..."
open "/Applications/Claude Usage.app"

echo "Done: $CONFIG build installed and launched."
