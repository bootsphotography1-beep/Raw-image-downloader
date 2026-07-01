#!/bin/bash
# RawDeck deployment-target diagnostic.
# Run on the Mac and paste the output. This will reveal why xcodebuild
# is treating the project as a macOS 11 target when the project file
# says MACOSX_DEPLOYMENT_TARGET = 13.0.

set +e

echo "=== macOS host version ==="
sw_vers

echo ""
echo "=== xcodebuild version ==="
xcodebuild -version

echo ""
echo "=== xcode-select path ==="
xcode-select -p

echo ""
echo "=== Available macOS SDKs ==="
xcodebuild -showsdks 2>&1 | grep -i "macos" | head -5

echo ""
echo "=== Xcode apps in /Applications ==="
ls -la /Applications/ 2>/dev/null | grep -i xcode

echo ""
echo "=== RawDeck resolved build settings ==="
cd ~/projects/RawDeck/RawDeck
xcodebuild -scheme RawDeck -showBuildSettings 2>&1 | grep -E "MACOSX_DEPLOYMENT_TARGET|^\s+SDKROOT|^\s+PLATFORM_NAME|^\s+SWIFT_VERSION|^\s+ARCHS|^\s+EFFECTIVE_PLATFORM_NAME" | sort -u