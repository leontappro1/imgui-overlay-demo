#!/usr/bin/env bash
# Run on a Mac. Produces ./build/ipa/ImGuiOverlayIOS.ipa
# This is the LEGAL way to get an .ipa: archive your OWN Xcode project and export it.
set -e
cd "$(dirname "$0")"

: "${DEV_TEAM:?set DEV_TEAM to your Apple Developer Team ID, e.g. DEV_TEAM=ABCDE12345 ./build_ipa.sh}"

./build_ios.sh device

mkdir -p build
xcodebuild \
  -project build-device/ImGuiOverlayIOS.xcodeproj \
  -target ImGuiOverlayIOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$(pwd)/build/ImGuiOverlay.xcarchive" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEV_TEAM" \
  clean archive

# Replace YOUR_TEAM_ID in ExportOptions.plist with your real Team ID.
TEAM_PLIST="build/ExportOptions.plist"
sed "s/YOUR_TEAM_ID/$DEV_TEAM/g" ExportOptions.plist > "$TEAM_PLIST"

xcodebuild -exportArchive \
  -archivePath "$(pwd)/build/ImGuiOverlay.xcarchive" \
  -exportPath "$(pwd)/build/ipa" \
  -exportOptionsPlist "$TEAM_PLIST" \
  -allowProvisioningUpdates

echo
echo "IPA -> $(pwd)/build/ipa/ImGuiOverlayIOS.ipa"
echo "Install on a registered device: Xcode > Window > Devices and Simulators > +"
