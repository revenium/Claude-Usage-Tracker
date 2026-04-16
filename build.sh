#!/bin/bash
# Build Claude Usage (Debug by default, pass "Release" as first arg for release build)
set -e

CONFIG=${1:-Debug}

xcodebuild \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration "$CONFIG" \
  -destination "platform=macOS" \
  build

echo "Build complete: $CONFIG"
