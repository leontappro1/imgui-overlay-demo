#!/usr/bin/env bash
# Build an UNSIGNED iOS DEVICE (arm64, iphoneos) .app and pack it as .ipa.
# This is the file you sign afterwards with ESign / Sideloadly / AltStore.
# It is NOT a simulator build - the Mach-O platform is iOS (LC_BUILD_VERSION
# platform 2), which is now verified MANDATORY before packing.
# Runs on macOS only (local Mac or a GitHub Actions macOS runner).
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${BUNDLE_ID:-com.maksim.imguioverlay}"

# Icons are drawn from scratch by a pure stdlib script, so a fresh checkout
# always ends up with valid RGB PNGs (iOS rejects icons with an alpha channel).
if command -v python3 >/dev/null 2>&1 && [ -f make_icons.py ]; then
  echo "==> generating icons"
  python3 make_icons.py
fi

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

# NOTE: "-derivedDataPath" is only accepted together with -scheme. Passing it
# together with -target makes xcodebuild bail out with
# "The flag -scheme, -testProductsPath, or -xctestrun is required when
# specifying -derivedDataPath", so -scheme is the primary form here.
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

if ! run_xcodebuild -scheme ImGuiOverlayIOS -destination 'generic/platform=iOS'; then
  echo "==> -scheme failed, retrying with -target/-sdk (no -derivedDataPath)" | tee -a build-dev.log
  xcodebuild \
    -project build-dev/ImGuiOverlayIOS.xcodeproj \
    -configuration Release \
    -sdk iphoneos \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -target ImGuiOverlayIOS \
    build 2>&1 | tee -a build-dev.log
fi

# CMake's Xcode generator puts products in build-dev/Release/, not in DerivedData.
APP=$(find build-dev -name '*.app' -type d -print -quit)
if [ -z "$APP" ]; then
  APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name 'ImGuiOverlayIOS.app' -type d -print -quit 2>/dev/null || true)
fi
if [ -z "$APP" ]; then
  echo "no .app produced, build tree:" >&2
  find build-dev -maxdepth 3 >&2
  exit 1
fi
echo "==> found $APP"

EXEC=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$APP/Info.plist" 2>/dev/null || echo "ImGuiOverlayIOS")
BIN="$APP/$EXEC"

# ---------------------------------------------------------------- diagnostics
# Zipped into build-dev.log AND written to build-info.txt, which the workflow
# publishes as ::notice:: annotations (readable through the public checks API).
ARCH=$(lipo -info "$BIN" 2>/dev/null || file "$BIN")
PLAT=$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}' || true)
BID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist" 2>/dev/null || echo "?")
MINOS=$(/usr/bin/plutil -extract MinimumOSVersion raw -o - "$APP/Info.plist" 2>/dev/null || echo "not-in-plist")
CAPS=$(/usr/bin/plutil -extract UIRequiredDeviceCapabilities raw -o - "$APP/Info.plist" 2>/dev/null || echo "none")
ICONS=$(find "$APP" -maxdepth 1 -name '*.png' -exec basename {} \; | tr '\n' ' ')

DIAG=$(cat <<EOF
bundle-id: $BID
executable: $EXEC
arch: $ARCH
platform: ${PLAT:-unknown} (2=iOS, 7=iOSSimulator, 1=macOS, 6=macCatalyst)
min-os: $MINOS
capabilities: $CAPS
icons in .app: ${ICONS:-NONE}
EOF
)
echo "$DIAG" | tee -a build-dev.log
echo "$DIAG" > build-info.txt
echo "bundle files:" | tee -a build-dev.log
# Capture first: with `set -o pipefail`, a `head` closing early can SIGPIPE find
# and fail the whole script even though the build itself was fine.
FILELIST=$(find "$APP" -maxdepth 2 | sed "s|$APP|.|" | head -30 || true)
echo "$FILELIST" | tee -a build-dev.log

# ---------------------------------------------------------------- hard guards
if [ "$PLAT" != "2" ]; then
  echo "ERROR: Mach-O platform is '${PLAT:-unknown}', expected 2 (iOS device)." >&2
  echo "       A simulator/macOS binary can be signed but NEVER installed on a phone." >&2
  exit 1
fi
if ! echo "$ARCH" | grep -q 'arm64'; then
  echo "ERROR: binary is not arm64: $ARCH" >&2
  exit 1
fi
if [ -z "$ICONS" ]; then
  echo "ERROR: no PNG icons in the .app - installd may reject the install." >&2
  exit 1
fi

# ---------------------------------------------------------------- pack
rm -rf out-dev
mkdir -p out-dev/Payload
cp -R "$APP" out-dev/Payload/
BUNDLE="out-dev/Payload/$(basename "$APP")"
# Belt and braces: guarantee the icons are inside the IPA even if the CMake
# Xcode generator skipped its Copy Bundle Resources phase.
cp -f icons/*.png "$BUNDLE/"
(cd out-dev && zip -qry -X ImGuiOverlayIOS-device-unsigned.ipa Payload)

echo
echo "==> out-dev/ImGuiOverlayIOS-device-unsigned.ipa"
ls -lh out-dev/ImGuiOverlayIOS-device-unsigned.ipa
IPALIST=$(unzip -l out-dev/ImGuiOverlayIOS-device-unsigned.ipa | head -20 || true)
echo "$IPALIST"
echo
echo "Next: sign this .ipa with ESign / Sideloadly / AltStore, then install."
echo "      (It has no _CodeSignature and no embedded.mobileprovision on purpose.)"
