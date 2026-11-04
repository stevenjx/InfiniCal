#!/bin/bash
# Builds a universal (arm64 + x86_64) InfiniCal.app without Xcode.
# Xcode users: open InfiniCal.xcodeproj instead (same sources, same result).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/InfiniCal.app"
MIN="12.0"
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ -x "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
  SWIFTC="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
  SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
  SWIFTC="$(xcrun -f swiftc)"
  SDK="$(xcrun --show-sdk-path)"
fi

# Reject source/version drift and run hardware-free regression tests before build.
python3 "$ROOT/Tools/quality_gate.py" source
python3 "$ROOT/Tools/quality_gate.py" test

# Only clean our own products; keep Xcode DerivedData (build/xcode) intact.
rm -rf "$APP" "$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/Helper" "$APP/Contents/Frameworks" "$BUILD/obj"

SPARKLE="$ROOT/Vendor/Sparkle.framework"

SOURCES=(
  "$ROOT/Sources/Core/SMC.swift"
  "$ROOT/Sources/Core/L10n.swift"
  "$ROOT/Sources/Core/Battery.swift"
  "$ROOT/Sources/Core/PowerMeter.swift"
  "$ROOT/Sources/Core/PowerEstimate.swift"
  "$ROOT/Sources/Core/PowerFormat.swift"
  "$ROOT/Sources/Core/ChargeController.swift"
  "$ROOT/Sources/Core/ChargeArbitration.swift"
  "$ROOT/Sources/Core/ControlResult.swift"
  "$ROOT/Sources/Core/DeviceProfile.swift"
  "$ROOT/Sources/Core/DeviceProfileStore.swift"
  "$ROOT/Sources/Core/Advice.swift"
  "$ROOT/Sources/Core/AdviceProvider.swift"
  "$ROOT/Sources/Core/SystemChargeLimit.swift"
  "$ROOT/Sources/Core/Models.swift"
  "$ROOT/Sources/Core/CalibrationModel.swift"
  "$ROOT/Sources/Core/CalibrationMath.swift"
  "$ROOT/Sources/Core/CalibrationEngine.swift"
  "$ROOT/Sources/Core/GPUStress.swift"
  "$ROOT/Sources/Core/ProcessSampler.swift"
  "$ROOT/Sources/Core/HIDThermal.swift"
  "$ROOT/Sources/Core/HistoryStore.swift"
  "$ROOT/Sources/Core/SparkleUpdater.swift"
  "$ROOT/Sources/UI/UpdatePanel.swift"
  "$ROOT/Sources/Core/Notifier.swift"
  "$ROOT/Sources/Core/AnomalyAlerts.swift"
  "$ROOT/Sources/Core/SleepControl.swift"
  "$ROOT/Sources/Core/FanController.swift"
  "$ROOT/Sources/Core/Typography.swift"
  "$ROOT/Sources/Core/Metrics.swift"
  "$ROOT/Sources/Core/Theme.swift"
  "$ROOT/Sources/Core/AppState.swift"
  "$ROOT/Sources/UI/PageScaffold.swift"
  "$ROOT/Sources/UI/Charts.swift"
  "$ROOT/Sources/UI/PowerFlowView.swift"
  "$ROOT/Sources/UI/DashboardView.swift"
  "$ROOT/Sources/UI/ChargeControlView.swift"
  "$ROOT/Sources/UI/CalibrationPanel.swift"
  "$ROOT/Sources/UI/FanControlView.swift"
  "$ROOT/Sources/UI/PanelsBattery.swift"
  "$ROOT/Sources/UI/PanelsAutomation.swift"
  "$ROOT/Sources/UI/PanelsAppearance.swift"
  "$ROOT/Sources/UI/HardwareDiagnosticsView.swift"
  "$ROOT/Sources/UI/DeviceProfileCard.swift"
  "$ROOT/Sources/UI/HistoryPanel.swift"
  "$ROOT/Sources/UI/AdviceCard.swift"
  "$ROOT/Sources/UI/RootView.swift"
  "$ROOT/Sources/UI/AppDelegate.swift"
  "$ROOT/Sources/UI/MenuBar.swift"
  "$ROOT/Sources/UI/FirstRunHelperSheet.swift"
  "$ROOT/Sources/main.swift"
)

HELPER_SOURCES=(
  "$ROOT/Sources/Core/L10n.swift"
  "$ROOT/Sources/Core/SMC.swift"
  "$ROOT/Helper/main.swift"
)

build_arch() {
  local arch="$1"
  echo "==> building $arch"
  "$SWIFTC" -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos$MIN" \
    -module-name InfiniCal -o "$BUILD/obj/InfiniCal-$arch" \
    -F "$ROOT/Vendor" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    "${SOURCES[@]}"
  "$SWIFTC" -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos$MIN" \
    -module-name InfiniCalHelper -o "$BUILD/obj/helper-$arch" "${HELPER_SOURCES[@]}"
}

build_arch arm64
build_arch x86_64

lipo -create "$BUILD/obj/InfiniCal-arm64" "$BUILD/obj/InfiniCal-x86_64" -output "$APP/Contents/MacOS/InfiniCal"
lipo -create "$BUILD/obj/helper-arm64" "$BUILD/obj/helper-x86_64" -output "$APP/Contents/Library/Helper/com.infinitycomputer.infinical.helper"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/en.json" "$APP/Contents/Resources/en.json"

# Sparkle ships as an already-signed framework; copy it verbatim and keep its
# XPC services intact. Re-signing with --deep would break Installer.xpc.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

chmod +x "$APP/Contents/MacOS/InfiniCal" "$APP/Contents/Library/Helper/com.infinitycomputer.infinical.helper"

# Ad-hoc signature so the app can run locally (replace with a Developer ID for
# distribution). Sign inside-out and never with --deep: Sparkle's Installer and
# Downloader XPC services carry their own signature and entitlements.
codesign --force --sign - --timestamp=none "$APP/Contents/Library/Helper/com.infinitycomputer.infinical.helper"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none "$APP"
python3 "$ROOT/Tools/quality_gate.py" artifact

echo "==> built $APP"
lipo -info "$APP/Contents/MacOS/InfiniCal"
lipo -info "$APP/Contents/Library/Helper/com.infinitycomputer.infinical.helper"
