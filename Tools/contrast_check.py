#!/usr/bin/env python3
"""WCAG contrast audit for the palette in Sources/Core/Theme.swift.

Why parse the Swift instead of copying the numbers here
  A second copy of the palette would drift the day someone edits Theme.swift,
  and the check would keep passing while the app got harder to read. The parser
  is deliberately narrow: it understands exactly the three shapes the theme
  uses (literal RGB, white/black with opacity, and an alias to another token)
  and raises on anything else, so a new shape fails loudly instead of being
  skipped.

Thresholds
  4.5:1 for text, per WCAG 2.1 AA for normal-size text. `card` is the surface
  most text sits on; `windowBackground` is the other one. `innerControl` is
  reported but not enforced — reaching 4.5:1 on a 0.906 grey would push the
  whole text ladder several steps darker, and almost no tertiary text sits
  there.

Usage
  python3 Tools/contrast_check.py          # table, exit 1 on failure
  python3 Tools/contrast_check.py --all    # include the informational rows
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
THEME = ROOT / "Sources/Core/Theme.swift"

AA = 4.5

# foreground tokens that carry text, and the surfaces they sit on
TEXT_TOKENS = ["textPrimary", "textSecondary", "textTertiary", "success", "warning", "danger"]
SURFACES = ["card", "windowBackground"]
INFO_SURFACE = "innerControl"
SERIES = ["flowAdapter", "flowSystem", "flowBattery", "flowSoC", "flowUSB", "flowOther"]

RGB = re.compile(r"Color\(red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+)\)")
INK = re.compile(r"Color\.(white|black)\.opacity\(([\d.]+)\)")
DECL = re.compile(r"^\s*var (\w+): Color \{ (.+) \}\s*$")


def parse():
    """token -> (dark, light), each (r, g, b, a) in 0…1."""
    raw, aliases = {}, {}
    for line in THEME.read_text().splitlines():
        m = DECL.match(line)
        if not m:
            continue
        name, expr = m.group(1), m.group(2).strip()
        if expr in ("accent", "info"):
            aliases[name] = expr
            continue
        if "isDark ?" not in expr:
            raw[name] = (value(expr), value(expr))
            continue
        dark, light = expr.split("isDark ?", 1)[1].split(" : ", 1)
        raw[name] = (value(dark.strip()), value(light.strip()))

    for name, target in aliases.items():
        if target in raw:
            raw[name] = raw[target]
    return raw


def value(expr):
    m = RGB.search(expr)
    if m:
        return (float(m.group(1)), float(m.group(2)), float(m.group(3)), 1.0)
    m = INK.search(expr)
    if m:
        base = 1.0 if m.group(1) == "white" else 0.0
        return (base, base, base, float(m.group(2)))
    if expr == "Color.white":
        return (1.0, 1.0, 1.0, 1.0)
    if expr == "Color.black":
        return (0.0, 0.0, 0.0, 1.0)
    raise SystemExit(f"contrast_check: cannot parse colour expression {expr!r} — "
                     "extend the parser or use one of the three known shapes")


def over(fg, bg):
    """Composite an alpha colour onto an opaque background, in sRGB."""
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)


def luminance(c):
    def channel(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(x) for x in c[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(fg, bg):
    a, b = luminance(fg), luminance(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def main():
    show_all = "--all" in sys.argv
    palette = parse()
    failures, rows = [], []

    for mode, index in (("dark", 0), ("light", 1)):
        for token in TEXT_TOKENS:
            if token not in palette:
                raise SystemExit(f"contrast_check: {token} missing from Theme.swift")
            for surface in SURFACES + [INFO_SURFACE]:
                bg = palette[surface][index]
                fg = over(palette[token][index], bg)
                r = ratio(fg, bg)
                enforced = surface in SURFACES
                rows.append((mode, token, surface, r, enforced))
                if enforced and r < AA:
                    failures.append((mode, token, surface, r))
        for token in SERIES:
            if token not in palette:
                continue
            bg = palette["card"][index]
            r = ratio(over(palette[token][index], bg), bg)
            rows.append((mode, token, "card", r, False))
            if r < AA:
                failures.append((mode, token, "card", r))

    print(f"{'mode':5} {'token':16} {'on':17} {'ratio':>6}  ")
    for mode, token, surface, r, enforced in rows:
        if not show_all and not enforced:
            continue
        mark = "ok " if r >= AA else "LOW"
        print(f"{mode:5} {token:16} {surface:17} {r:6.2f}  {mark}")

    if failures:
        print(f"\nFAIL contrast: {len(failures)} pair(s) below {AA}:1", file=sys.stderr)
        for mode, token, surface, r in failures:
            print(f"  {mode}: {token} on {surface} = {r:.2f}:1", file=sys.stderr)
        return 1

    enforced_rows = [r for r in rows if r[4]]
    worst = min(enforced_rows, key=lambda r: r[3])
    print(f"\nPASS contrast: {len(enforced_rows)} pairs at or above {AA}:1 "
          f"(worst {worst[0]} {worst[1]} on {worst[2]} = {worst[3]:.2f}:1)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
