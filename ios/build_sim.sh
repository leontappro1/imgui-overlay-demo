#!/usr/bin/env bash
# Build an UNSIGNED iOS Simulator .app and pack it into an .ipa-shaped archive.
# Does NOT need an Apple account, a certificate or a physical device.
# Runs on macOS only (local Mac or a GitHub Actions macOS runner).
set -euo pipefail
cd "$(dirname "$0")"

# Icons are drawn from scratch by a pure stdlib script, so a fresh checkout
# always ends up with valid RGB PNGs (iOS rejects icons with an alpha channel).
if command -v python3 >/dev/null 2>&1 && [ -f make_icons.py ]; then
  echo "==> generating icons"
  python3 make_icons.py
fi

BUNDLE_ID="${BUNDLE_ID:-com.maksim.imguioverlay}"

echo "==> cmake -G Xcode (iOS Simulator)"
cmake -S . -B build-sim -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUNDLE_ID="$BUNDLE_ID" \
  -DDEV_TEAM=""

echo "==> xcodebuild (unsigned)"
: > build-sim.log

# -sdk is the reliable form for a CMake-generated project built with -target.
# "-destination 'generic/platform=iOS Simulator'" together with -target made
# xcodebuild exit 64 (EX_USAGE) on the macOS runner, so it is only used as a
# fallback together with -scheme.
run_xcodebuild() {
  xcodebuild \
    -project build-sim/ImGuiOverlayIOS.xcodeproj \
    -configuration Release \
    -derivedDataPath build-sim/dd \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$@" \
    build 2>&1 | tee -a build-sim.log
}

if ! run_xcodebuild -target ImGuiOverlayIOS -sdk iphonesimulator; then
  echo "==> -target/-sdk failed, retrying with -scheme/-destination" | tee -a build-sim.log
  run_xcodebuild -scheme ImGuiOverlayIOS -destination 'generic/platform=iOS Simulator'
fi

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
