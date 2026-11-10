#!/usr/bin/env bash
# Build an UNSIGNED iOS DEVICE (arm64, iphoneos) .app and pack it as .ipa.
# This is the file you sign afterwards with ESign / Sideloadly / AltStore.
# It is NOT a simulator build - the Mach-O platform is iOS, not iOSSimulator.
# Runs on macOS only (local Mac or a GitHub Actions macOS runner).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${BUNDLE_ID:-com.example.imguioverlay}"

echo "==> cmake -G Xcode (iphoneos / arm64)"
cmake -S . -B build-dev -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUNDLE_ID="$BUNDLE_ID" \
  -DDEV_TEAM=""

echo "==> xcodebuild (device, unsigned)"
: > build-dev.log

# -sdk is the reliable form for a CMake-generated project built with -target.
# "-destination 'generic/platform=iOS'" together with -target made xcodebuild
# exit 64 (EX_USAGE) on the macOS runner, so it is only a fallback with -scheme.
run_xcodebuild() {
  xcodebuild \
    -project build-dev/ImGuiOverlayIOS.xcodeproj \
    -configuration Release \
    -derivedDataPath build-dev/dd \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    "$@" \
    build 2>&1 | tee -a build-dev.log
}

if ! run_xcodebuild -target ImGuiOverlayIOS -sdk iphoneos; then
  echo "==> -target/-sdk failed, retrying with -scheme/-destination" | tee -a build-dev.log
  run_xcodebuild -scheme ImGuiOverlayIOS -destination 'generic/platform=iOS'
fi

# CMake's Xcode generator puts products in build-dev/Release/, not in DerivedData.
APP=$(find build-dev -name '*.app' -type d -print -quit)
if [ -z "$APP" ]; then
  echo "no .app produced, build tree:" >&2
  find build-dev -maxdepth 3 >&2
  exit 1
fi
echo "==> found $APP"

# Guard against accidentally shipping a simulator slice: signing cannot fix that.
EXEC=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$APP/Info.plist" 2>/dev/null || echo "ImGuiOverlayIOS")
BIN="$APP/$EXEC"
echo
echo "Binary platform check:"
file "$BIN" || true
if command -v vtool >/dev/null 2>&1; then
  BUILD_INFO=$(vtool -show-build "$BIN" 2>/dev/null || true)
  echo "$BUILD_INFO" | head -10 || true
  # No grep -q here: with `set -o pipefail` an early grep exit can SIGPIPE vtool
  # and turn the pipeline into a false negative.
  if echo "$BUILD_INFO" | grep -i 'platform iOSSimulator' >/dev/null; then
    echo "ERROR: got a simulator binary - this .ipa would NOT install on a phone." >&2
    exit 1
  fi
fi

rm -rf out-dev
mkdir -p out-dev/Payload
cp -R "$APP" out-dev/Payload/
(cd out-dev && zip -qry ImGuiOverlayIOS-device-unsigned.ipa Payload)

echo
echo "==> out-dev/ImGuiOverlayIOS-device-unsigned.ipa"
ls -lh out-dev/ImGuiOverlayIOS-device-unsigned.ipa
unzip -l out-dev/ImGuiOverlayIOS-device-unsigned.ipa | head -12
echo
echo "Next: sign this .ipa with ESign / Sideloadly / AltStore, then install."
echo "      (It has no _CodeSignature and no embedded.mobileprovision on purpose.)"
