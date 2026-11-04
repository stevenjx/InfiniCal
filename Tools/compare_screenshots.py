#!/usr/bin/env python3
"""Compare panel screenshots against the committed baseline (U2-05).

Screenshots are captured by Tools/capture_panels.sh at 1080 px wide. They are
never byte-identical between runs — the clock, the battery percentage and the
live charts all move — so the check is a pixel-difference ratio with a
tolerance, not an exact match. The default threshold is calibrated by running
two captures back to back and taking the observed noise floor times three.

Usage:
  python3 Tools/compare_screenshots.py                 # check
  python3 Tools/compare_screenshots.py --update        # accept current as baseline
  python3 Tools/compare_screenshots.py --write-diff DIR
  python3 Tools/compare_screenshots.py --threshold 0.05
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "Tools/screenshots"
BASELINE = SHOTS / "baseline"
CURRENT = SHOTS / "current"

# 2 % of the frame may differ before it counts as a visual change. Live values
# (percentage, watts, clock) sit well under 1 %; a moved card or a changed font
# size is an order of magnitude above it.
DEFAULT_THRESHOLD = 0.02

# Some panels are legitimately unstable. The charge-control page grows an
# "adapter conversion loss" row only when the adapter is actually delivering
# power, and that row shifts everything below it. A per-panel override keeps
# that noise from either failing every run or loosening the other fifteen.
THRESHOLDS = SHOTS / "thresholds.json"


def threshold_for(name, fallback):
    if not THRESHOLDS.exists():
        return fallback
    config = json.loads(THRESHOLDS.read_text())
    return config.get("overrides", {}).get(str(name), config.get("default", fallback))

# Per-pixel channel delta below this is treated as anti-aliasing noise.
PIXEL_TOLERANCE = 12


def difference_ratio(base, current):
    if current.size != base.size:
        current = current.resize(base.size)
    diff = ImageChops.difference(base.convert("RGB"), current.convert("RGB")).convert("L")
    mask = diff.point(lambda value: 255 if value > PIXEL_TOLERANCE else 0)
    histogram = mask.histogram()
    changed = histogram[255]
    total = base.size[0] * base.size[1]
    return changed / total if total else 0.0, mask


def panels():
    """Every baseline image, relative to its appearance directory."""
    if not BASELINE.is_dir():
        return []
    return sorted(path.relative_to(BASELINE) for path in BASELINE.rglob("*.png"))


def main():
    parser = argparse.ArgumentParser(description="Panel screenshot diff")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                        help="allowed fraction of differing pixels (default 2%%)")
    parser.add_argument("--update", action="store_true",
                        help="copy current screenshots over the baseline")
    parser.add_argument("--write-diff", type=Path, default=None,
                        help="directory for diff masks")
    parser.add_argument("--allow-new", action="store_true",
                        help="treat a missing baseline image as a pass")
    args = parser.parse_args()

    if args.update:
        if not CURRENT.is_dir():
            sys.exit("no current screenshots — run Tools/capture_panels.sh first")
        count = 0
        for path in sorted(CURRENT.rglob("*.png")):
            target = BASELINE / path.relative_to(CURRENT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            count += 1
        print(f"baseline updated: {count} image(s)")
        return 0

    names = panels()
    if not names:
        sys.exit("no baseline images — run with --update after capturing")

    failures, missing, worst = [], [], (0.0, None)
    for name in names:
        base_path = BASELINE / name
        current_path = CURRENT / name
        if not current_path.exists():
            missing.append(str(name))
            continue
        with Image.open(base_path) as base_image, Image.open(current_path) as current_image:
            ratio, mask = difference_ratio(base_image, current_image)
        if ratio > worst[0]:
            worst = (ratio, name)
        limit = threshold_for(name, args.threshold)
        status = "ok" if ratio <= limit else "CHANGED"
        print(f"  {status:7s} {str(name):28s} {ratio * 100:5.2f}%")
        if args.write_diff is not None:
            args.write_diff.mkdir(parents=True, exist_ok=True)
            mask.save(args.write_diff / f"{name.parent.name}-{name.stem}.png")
        if ratio > limit:
            failures.append((str(name), ratio, limit))

    if missing:
        for name in missing:
            print(f"  {'MISSING':7s} {name}", file=sys.stderr)
        if not args.allow_new:
            failures.extend((name, 1.0, args.threshold) for name in missing)

    if failures:
        print(f"FAIL screenshots: {len(failures)} panel(s) changed "
              f"(threshold {args.threshold * 100:.1f}%)", file=sys.stderr)
        for name, ratio, limit in failures:
            print(f"  {name}: {ratio * 100:.2f}% of pixels differ "
                  f"(limit {limit * 100:.1f}%)", file=sys.stderr)
        print("  Inspect the images, then --update if the change is intended.",
              file=sys.stderr)
        return 1

    print(f"PASS screenshots: {len(names)} panel(s) within their limits "
          f"(worst {worst[1]} at {worst[0] * 100:.2f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
