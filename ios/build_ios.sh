#!/usr/bin/env bash
# Run on a Mac with Xcode + CMake installed.
#   ./build_ios.sh simulator   -> builds for iOS Simulator
#   ./build_ios.sh device      -> builds for a physical iPhone/iPad
set -e
cd "$(dirname "$0")"

MODE="${1:-simulator}"
if [ "$MODE" = "device" ]; then
  SYSROOT=iphoneos
  ARCH_ARGS=(-DCMAKE_OSX_ARCHITECTURES=arm64)
  DEST="generic/platform=iOS"
else
  SYSROOT=iphonesimulator
  ARCH_ARGS=()
  DEST="generic/platform=iOS Simulator"
fi

cmake -S . -B "build-$MODE" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SYSROOT" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DDEV_TEAM="${DEV_TEAM:-}" \
  -DBUNDLE_ID="${BUNDLE_ID:-com.example.imguioverlay}" \
  "${ARCH_ARGS[@]}"

echo
echo "Xcode project: $(pwd)/build-$MODE/ImGuiOverlayIOS.xcodeproj"
echo "Open it, pick a simulator/device, Cmd+R. Or:"
echo
echo "  xcodebuild -project build-$MODE/ImGuiOverlayIOS.xcodeproj \\"
echo "    -target ImGuiOverlayIOS -configuration Debug \\"
echo "    -destination '$DEST' build"
echo
echo "For an .ipa run ./build_ipa.sh instead."
