#!/usr/bin/env bash
# Build an UNSIGNED iOS Simulator .app and pack it into an .ipa-shaped archive.
# Does NOT need an Apple account, a certificate or a physical device.
# Runs on macOS only (local Mac or a GitHub Actions macOS runner).
set -e
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
xcodebuild \
  -project build-sim/ImGuiOverlayIOS.xcodeproj \
  -scheme ImGuiOverlayIOS \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-sim/dd \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP=$(find build-sim/dd/Build/Products -maxdepth 2 -name '*.app' -type d | head -1)
if [ -z "$APP" ]; then
  echo "no .app produced, contents of Build/Products:" >&2
  find build-sim/dd/Build/Products -maxdepth 3 >&2
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
