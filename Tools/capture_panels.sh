#!/bin/bash
# Capture every panel in both appearances for visual regression (U2-05).
#
# Why not `open --args --panel`: on this machine LaunchServices drops the
# arguments, and `osascript ... activate` launches a second instance without
# them. Running the binary directly keeps argv, and Tools/window_tool.swift
# brings that instance forward so `screencapture -l` can grab it.
#
# Usage:
#   bash Tools/capture_panels.sh                  # → Tools/screenshots/current
#   bash Tools/capture_panels.sh --baseline       # → Tools/screenshots/baseline
#   bash Tools/capture_panels.sh --panels dashboard,history
#
# Output is normalised to 1080 px wide so a diff is comparable across Retina
# and non-Retina machines.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/InfiniCal.app"
BINARY="$APP/Contents/MacOS/InfiniCal"
BUNDLE_ID="com.infinitycomputer.infinical"
TOOL_BIN="${TMPDIR:-/tmp}/infinical-window-tool"

PANELS=(dashboard calibration chargeControl fanControl sleep history schedule other)
APPEARANCES=(dark light)
TARGET="$ROOT/Tools/screenshots/current"

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) TARGET="$ROOT/Tools/screenshots/baseline" ;;
    --out) shift; TARGET="$1" ;;
    --panels) shift; IFS=',' read -r -a PANELS <<< "$1" ;;
    --appearances) shift; IFS=',' read -r -a APPEARANCES <<< "$1" ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

if [ ! -x "$BINARY" ]; then
  echo "build/InfiniCal.app missing — run the build first" >&2
  exit 1
fi

mkdir -p "$TARGET"

echo "==> compiling window tool"
xcrun swiftc -O "$ROOT/Tools/window_tool.swift" -o "$TOOL_BIN"

ORIGINAL_MODE="$(defaults read "$BUNDLE_ID" colorMode 2>/dev/null || echo 2)"
# The dashboard charts only fill while the app is frontmost, which a capture
# run cannot guarantee (it is not an interactive session). Turning the
# background-update switch on for the duration gives every screenshot a real
# curve instead of a one-point buffer; the user's value is restored on exit.
ORIGINAL_BG="$(defaults read "$BUNDLE_ID" dashboardBackgroundUpdates 2>/dev/null || echo 0)"
case "$ORIGINAL_BG" in
  1|true|yes) ORIGINAL_BG=true ;;
  *) ORIGINAL_BG=false ;;
esac

cleanup() {
  pkill -f "InfiniCal.app/Contents/MacOS" 2>/dev/null || true
  defaults write "$BUNDLE_ID" colorMode -int "$ORIGINAL_MODE"
  defaults write "$BUNDLE_ID" dashboardBackgroundUpdates -bool "$ORIGINAL_BG"
  rm -f "$TOOL_BIN"
}
trap cleanup EXIT

defaults write "$BUNDLE_ID" dashboardBackgroundUpdates -bool true

for appearance in "${APPEARANCES[@]}"; do
  case "$appearance" in
    dark) mode=2 ;;
    light) mode=1 ;;
    *) echo "unknown appearance: $appearance" >&2; exit 64 ;;
  esac
  mkdir -p "$TARGET/$appearance"

  for panel in "${PANELS[@]}"; do
    pkill -f "InfiniCal.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    defaults write "$BUNDLE_ID" colorMode -int "$mode"

    # Double fork: the subshell exits at once, so bash does not print a
    # "Terminated" line for every panel when the next pkill reaps the app.
    ( "$BINARY" --panel "$panel" >/dev/null 2>&1 & )
    # The dashboard samples its chart history every 2 s; a 4 s wait leaves a
    # single point, which draws as an empty box. Everything else is static.
    if [ "$panel" = "dashboard" ]; then sleep 24; else sleep 4; fi

    pid="$(pgrep -f "InfiniCal.app/Contents/MacOS" | head -1 || true)"
    if [ -z "$pid" ]; then
      echo "FAIL $appearance/$panel: app did not start" >&2
      continue
    fi

    if ! window_id="$("$TOOL_BIN" "$pid" 2>/dev/null)"; then
      echo "FAIL $appearance/$panel: no window id" >&2
      continue
    fi

    out="$TARGET/$appearance/$panel.png"
    if screencapture -x -o -l"$window_id" "$out" 2>/dev/null; then
      sips -Z 1080 "$out" >/dev/null 2>&1
      echo "  captured $appearance/$panel"
    else
      echo "FAIL $appearance/$panel: screencapture refused window $window_id" >&2
    fi
  done
done

pkill -f "InfiniCal.app/Contents/MacOS" 2>/dev/null || true
echo "==> wrote $TARGET"
