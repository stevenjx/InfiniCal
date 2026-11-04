#!/usr/bin/env python3
"""UI consistency lint for the design-token migration (U2-05).

Why a baseline instead of a hard rule
  The plan (UI_POLISH_PLAN.md) replaces 354 hand-written font sizes, 11 corner
  radii and 18 literal colours with tokens. Turning the rules on before the
  migration would fail every build, and a lint nobody can pass gets deleted.
  So each rule is a *ratchet*: the count per file may only go down. Finishing a
  page lowers the baseline with --update-baseline, and the rule can never drift
  back up.

Rules
  bare-font      .system(size:)            → Typography.*
  literal-color  Color(red:)               → Theme.*
  literal-radius cornerRadius: <number>    → Radius.*
  card-padding   Card(padding: <number>)   → .regular / .compact

Usage
  python3 Tools/ui_lint.py                 # check against the baseline
  python3 Tools/ui_lint.py --list          # print every file's counts
  python3 Tools/ui_lint.py --update-baseline
  python3 Tools/ui_lint.py --json
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Sources/UI plus the shared building blocks in Theme.swift. Typography.swift and
# Metrics.swift are deliberately out of scope: they are where the numbers live.
SCAN = [ROOT / "Sources/UI", ROOT / "Sources/Core/Theme.swift"]

# Theme.swift *defines* the colours, radii and card padding, so only the font
# rule applies to it; the other three would flag their own source of truth.
THEME_RULES = {"bare-font"}
BASELINE = Path(__file__).resolve().parent / "ui_lint_baseline.json"

RULES = {
    "bare-font": re.compile(r"\.system\(size:"),
    "literal-color": re.compile(r"Color\(red:"),
    "literal-radius": re.compile(r"cornerRadius:\s*[0-9]"),
    "card-padding": re.compile(r"Card\(padding:\s*[0-9]"),
}

HINTS = {
    "bare-font": "use Typography.display/title/headline/body/label/caption/micro",
    "literal-color": "use Theme.success/warning/danger/info or a chart colour",
    "literal-radius": "use Radius.chip/control/card/sheet",
    "card-padding": "use Card(padding: .regular) or .compact",
}


def scanned_files():
    files = []
    for entry in SCAN:
        files.extend(sorted(entry.glob("*.swift")) if entry.is_dir() else [entry])
    return files


def counts():
    result = {rule: {} for rule in RULES}
    for path in scanned_files():
        text = path.read_text()
        for rule, pattern in RULES.items():
            if path.name == "Theme.swift" and rule not in THEME_RULES:
                continue
            found = len(pattern.findall(text))
            if found:
                result[rule][path.name] = found
    return result


def load_baseline():
    if not BASELINE.exists():
        return {rule: {} for rule in RULES}
    data = json.loads(BASELINE.read_text())
    rules = data.get("rules", {})
    return {rule: rules.get(rule, {}) for rule in RULES}


def write_baseline(current):
    payload = {"version": 1, "rules": current}
    BASELINE.write_text(json.dumps(payload, ensure_ascii=False, indent=1, sort_keys=True) + "\n")


def regressions(current, baseline):
    """Every file whose count went up, plus files the baseline never knew."""
    problems = []
    for rule in RULES:
        base = baseline.get(rule, {})
        for file, count in sorted(current[rule].items()):
            allowed = base.get(file, 0)
            if count > allowed:
                problems.append((rule, file, count, allowed))
    return problems


def improvements(current, baseline):
    lowered = []
    for rule in RULES:
        base = baseline.get(rule, {})
        for file, allowed in sorted(base.items()):
            count = current[rule].get(file, 0)
            if count < allowed:
                lowered.append((rule, file, count, allowed))
    return lowered


def summary(current):
    return {rule: sum(current[rule].values()) for rule in RULES}


def main():
    parser = argparse.ArgumentParser(description="Design-token ratchet for Sources/UI")
    parser.add_argument("--update-baseline", action="store_true",
                        help="lower the baseline to the current counts")
    parser.add_argument("--list", action="store_true", help="print per-file counts")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    current = counts()
    baseline = load_baseline()

    if args.update_baseline:
        lowered = improvements(current, baseline)
        raised = regressions(current, baseline)
        write_baseline(current)
        total = summary(current)
        print("baseline updated: " + ", ".join(f"{k}={v}" for k, v in total.items()))
        for rule, file, count, allowed in raised:
            print(f"  note: {rule} {file} rose {allowed} → {count} and is now the baseline")
        for rule, file, count, allowed in lowered:
            print(f"  lowered {rule} {file}: {allowed} → {count}")
        return 0

    if args.list:
        for rule in RULES:
            print(f"{rule} ({HINTS[rule]})")
            for file, count in sorted(current[rule].items()):
                print(f"  {count:4d}  {file}")
        return 0

    problems = regressions(current, baseline)
    total = summary(current)
    base_total = {rule: sum(baseline[rule].values()) for rule in RULES}

    if args.json:
        print(json.dumps({"current": total, "baseline": base_total,
                          "regressions": problems}, ensure_ascii=False))
        return 1 if problems else 0

    if problems:
        print(f"FAIL ui_lint: {len(problems)} count(s) above baseline", file=sys.stderr)
        for rule, file, count, allowed in problems:
            print(f"  {rule}  Sources/UI/{file}: {count} (baseline {allowed}) — {HINTS[rule]}",
                  file=sys.stderr)
        print("  New code must use tokens; if a file legitimately grew, review it before "
              "running --update-baseline.", file=sys.stderr)
        return 1

    drift = [f"{rule} {sum(baseline[rule].values())}→{total[rule]}"
             for rule in RULES if total[rule] < sum(baseline[rule].values())]
    tail = (" (" + ", ".join(drift) + "; run --update-baseline to lock it in)") if drift else ""
    print("PASS ui_lint " + ", ".join(f"{k}={v}" for k, v in total.items()) + tail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
