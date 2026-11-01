#!/bin/bash
# Creates a DMG whose mounted volume uses the InfiniCal icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/Tools/quality_gate.py" all
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/build/InfiniCal.app/Contents/Info.plist")"
mkdir -p "$ROOT/dist"
OUTPUT="$ROOT/dist/InfiniCal-$VERSION.dmg"
if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite $OUTPUT" >&2
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/infinical-dmg.XXXXXX")"
MOUNT="$WORK/volume"
mkdir -p "$WORK/stage" "$MOUNT"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then hdiutil detach "$MOUNT" || true; fi
}
trap cleanup EXIT
ditto "$ROOT/build/InfiniCal.app" "$WORK/stage/InfiniCal.app"
ln -s /Applications "$WORK/stage/Applications"
cp "$ROOT/Resources/AppIcon.icns" "$WORK/stage/.VolumeIcon.icns"
hdiutil create -volname "InfiniCal $VERSION" -srcfolder "$WORK/stage" -format UDRW "$WORK/writable.dmg"
hdiutil attach -readwrite -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"
MOUNTED=1
SetFile -a C "$MOUNT"
SetFile -a V "$MOUNT/.VolumeIcon.icns"
# FinderInfo bit 0x0400 is the volume's custom-icon flag.
python3 - "$MOUNT" <<'PY'
import subprocess, sys
from pathlib import Path
volume = Path(sys.argv[1])
flags = bytes.fromhex(subprocess.check_output(['/usr/bin/xattr', '-px', 'com.apple.FinderInfo', str(volume)], text=True))
assert int.from_bytes(flags[8:10], 'big') & 0x0400, 'Custom icon flag missing'
assert (volume / '.VolumeIcon.icns').read_bytes() == (volume / 'InfiniCal.app/Contents/Resources/AppIcon.icns').read_bytes()
print('PASS mounted volume icon')
PY
hdiutil detach "$MOUNT"
MOUNTED=0
hdiutil convert "$WORK/writable.dmg" -format UDZO -o "$OUTPUT"
python3 "$ROOT/Tools/quality_gate.py" artifact --dmg "$OUTPUT"
echo "==> packaged $OUTPUT"
