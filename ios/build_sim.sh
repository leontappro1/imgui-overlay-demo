#!/usr/bin/env bash
# Build an UNSIGNED iOS Simulator .app and pack it into an .ipa-shaped archive.
# Does NOT need an Apple account, a certificate or a physical device.
# Runs on macOS only (local Mac or a GitHub Actions macOS runner).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${BUNDLE_ID:-com.example.imguioverlay}"

echo "==> cmake -G Xcode (iOS Simulator)"
cmake -S . -B build-sim -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUNDLE_ID="$BUNDLE_ID" \
  -DDEV_TEAM=""

echo "==> xcodebuild (unsigned)"
# -target, not -scheme: CMake's Xcode generator does not always emit a shared
# scheme, and "Scheme X is not currently configured for the build action" is
# the most common CI failure for CMake-generated iOS projects.
xcodebuild \
  -project build-sim/ImGuiOverlayIOS.xcodeproj \
  -target ImGuiOverlayIOS \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-sim/dd \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee build-sim.log

# CMake's Xcode generator puts products in build-sim/Release/ (CONFIGURATION_BUILD_DIR),
# NOT in DerivedData/Build/Products. Search the whole build tree.
APP=$(find build-sim -name '*.app' -type d -print -quit)
if [ -z "$APP" ]; then
  echo "no .app produced, build tree:" >&2
  find build-sim -maxdepth 3 >&2
  exit 1
fi
echo "==> found $APP"

rm -rf out
mkdir -p out/Payload
cp -R "$APP" out/Payload/
(cd out && zip -qry ImGuiOverlayIOS-simulator.ipa Payload)

echo
echo "==> out/ImGuiOverlayIOS-simulator.ipa"
ls -lh out/ImGuiOverlayIOS-simulator.ipa
unzip -l out/ImGuiOverlayIOS-simulator.ipa | head -12
echo
echo "NOTE: simulator slice + no signature -> inspect/verify the build, NOT installable on a phone."
echo "      For a real device .ipa see build_ipa.sh and README.md."
