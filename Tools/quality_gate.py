#!/usr/bin/env python3
"""Local quality gate; never starts the app, helper or hardware controls.

Usage: python3 Tools/quality_gate.py [source|test|artifact|all] [--dmg PATH]
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def source_gate():
    with (ROOT / "Resources/Info.plist").open("rb") as f:
        info = plistlib.load(f)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    assert re.fullmatch(r"\d+(?:\.\d+){2,3}", version), "Invalid app version"
    assert build.isdigit(), "Invalid build number"
    generator = (ROOT / "Tools/generate_xcodeproj.py").read_text()
    project = (ROOT / "InfiniCal.xcodeproj/project.pbxproj").read_text()
    for label, text in [("generator", generator), ("Xcode project", project)]:
        assert set(re.findall(r"MARKETING_VERSION = ([^;]+);", text)) == {version}, label + " version drift"
        assert set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)) == {build}, label + " build drift"
    tree = ast.parse(generator)
    assignments = {n.targets[0].id: ast.literal_eval(n.value) for n in tree.body
                   if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name)
                   and n.targets[0].id in ("APP_SOURCES", "HELPER_SOURCES")}
    script = (ROOT / "build.sh").read_text()
    for name, generated in assignments.items():
        shell_name = "SOURCES" if name == "APP_SOURCES" else name
        block = re.search(r"^" + shell_name + r"=\((.*?)^\)", script, re.M | re.S).group(1)
        shell = re.findall(r'"\$ROOT/([^"\n]+)"', block)
        assert len(shell) == len(set(shell)), "Duplicate build sources"
        assert set(shell) == set(generated), name + " source list drift"
        for path in shell:
            assert (ROOT / path).is_file(), "Missing source: " + path
    actual = {str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift")}
    assert actual == set(assignments["APP_SOURCES"]), "Swift source omitted from build"
    def unique(pairs):
        result = {}
        for key, value in pairs:
            assert key not in result, "Duplicate localization key: " + key
            result[key] = value
        return result
    translations = json.loads((ROOT / "Resources/en.json").read_text(), object_pairs_hook=unique)
    for key, value in translations.items():
        assert isinstance(value, str), "Non-string translation"
        assert key.count("{p}") == value.count("{p}"), "Placeholder drift: " + key
    run("git", "-C", ROOT, "diff", "--check")
    print("PASS source/version/localization gate", flush=True)


def tests():
    models = (ROOT / "Sources/Core/Models.swift").read_text()
    policy = models[models.index("enum ChargePolicy {"):models.index("\nstruct CalibrationRun {")]
    checkpoint_file = (ROOT / "Sources/Core/CalibrationModel.swift").read_text()
    checkpoint = checkpoint_file[checkpoint_file.index("struct CalibrationCheckpoint:"):checkpoint_file.index("/// One 1 Hz")]
    helper = (ROOT / "Helper/main.swift").read_text()
    validation = helper[helper.index("func isAllowedWriteKey("):helper.index("let allowedExecutables:")]
    record = checkpoint_file[checkpoint_file.index("struct CalibrationRecord:"):checkpoint_file.index("/// Weighted blend")]
    swift = "import Foundation\n" + policy + checkpoint + record + validation
    swift += (ROOT / "Sources/Core/ControlResult.swift").read_text()
    swift += (ROOT / "Sources/Core/CalibrationMath.swift").read_text()
    swift += '''
func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
for sailing in [false, true] {
    check(!ChargePolicy.allowsCharging(percentage: 80, limit: 80, sailing: sailing, difference: 5, previous: true, isCharging: true), "ceiling")
    check(ChargePolicy.allowsCharging(percentage: 75, limit: 80, sailing: sailing, difference: 5, previous: false, isCharging: false), "floor")
}
check(ChargePolicy.allowsCharging(percentage: 76, limit: 80, sailing: true, difference: 5, previous: true, isCharging: false), "continue topup")
check(!ChargePolicy.allowsCharging(percentage: 79, limit: 80, sailing: true, difference: 5, previous: false, isCharging: false), "continue hold")
for scope in ["-a", "-b", "-c"] {
    for value in ["0", "1"] { check(isSafeExec("/usr/bin/pmset", [scope, "lowpowermode", value]), "legitimate pmset") }
}
check(!isSafeExec("/usr/bin/pmset", ["-a", "lowpowermode", "1", "extra"]), "extra arg")
check(!isSafeExec("/usr/bin/pmset", ["-a", "sleep", "0"]), "unapproved setting")
check(!isSafeExec("/usr/bin/killall", ["powerd"]), "unapproved binary")
check(isSafeExec("/usr/bin/powermetrics", ["--samplers", "cpu_power", "-n", "1", "-i", "400"]), "bounded sample")
check(!isSafeExec("/usr/bin/powermetrics", ["--samplers", "cpu_power"]), "unbounded sample")
for key in ["BCLM", "CHIE", "CHTE", "FS! ", "F0Md", "F1Tg"] { check(isAllowedWriteKey(key), "allowed key") }
for key in ["ACEN", "XXXX", "F0Ac", "F９Md", "BCLMM"] { check(!isAllowedWriteKey(key), "denied key") }
let integrator = CoulombIntegrator()
_ = integrator.step(uptime: 0, currentSignedAmps: -1, voltageVolts: 12)
let first = integrator.step(uptime: 1, currentSignedAmps: -1, voltageVolts: 12)
check(abs(first.dischargeAh - 1.0/3600) < 1e-10, "integration")
let gap = integrator.step(uptime: 100, currentSignedAmps: -1, voltageVolts: 12)
check(gap.dischargeAh == first.dischargeAh, "do not integrate missing samples")
integrator.reset()
check(integrator.totals.dischargeAh == 0, "reset")
let c = CalibrationCheckpoint(sessionID: UUID(), phase: "discharging", startedAt: Date(), lastSampleAt: Date(), targetPercentage: 10, restoreLimit: 80, stressMode: "silent", adapterControl: "DisableInflow", chargeControl: "bclm", reason: "test")
let bytes = try JSONEncoder().encode(c)
let decoded = try JSONDecoder().decode(CalibrationCheckpoint.self, from: bytes)
check(decoded == c, "checkpoint round trip")
check((try? JSONDecoder().decode(CalibrationCheckpoint.self, from: Data("{}".utf8))) == nil, "corrupt checkpoint")
let evidence = ControlEvidence(operation: "test", backend: "mock", phase: .accepted)
check(evidence.observed == nil, "acceptance is not observation")
print("PASS pure policy/math/checkpoint/helper-validation tests (no hardware)")
'''
    with tempfile.TemporaryDirectory(prefix="infinical-tests-") as directory:
        main = Path(directory) / "main.swift"
        main.write_text(swift)
        executable = Path(directory) / "tests"
        run("xcrun", "swiftc", "-swift-version", "5", main, "-o", executable)
        run(executable)


def artifact_gate(dmg):
    app = ROOT / "build/InfiniCal.app"
    with (ROOT / "Resources/Info.plist").open("rb") as f:
        expected = plistlib.load(f)
    with (app / "Contents/Info.plist").open("rb") as f:
        actual = plistlib.load(f)
    for field in ["CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier", "LSMinimumSystemVersion"]:
        assert expected[field] == actual[field], "Artifact metadata drift: " + field
    for binary in [app / "Contents/MacOS/InfiniCal", app / "Contents/Library/Helper/com.infinitycomputer.infinical.helper"]:
        arches = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        assert {"arm64", "x86_64"}.issubset(arches), "Missing architecture: " + str(binary)
        run("codesign", "--verify", "--strict", binary)
    run("codesign", "--verify", "--deep", "--strict", app)
    assert (app / "Contents/Resources/en.json").read_bytes() == (ROOT / "Resources/en.json").read_bytes(), "Stale localization"
    if dmg:
        image = Path(dmg).resolve()
        run("hdiutil", "verify", image)
        # A read-only mount is necessary: a valid DMG checksum alone cannot
        # prove it contains the just-built version or helper.
        with tempfile.TemporaryDirectory(prefix="infinical-image-") as directory:
            run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", directory, image)
            try:
                contained = Path(directory) / "InfiniCal.app"
                assert contained.is_dir(), "DMG missing InfiniCal.app"
                for local in app.rglob("*"):
                    if local.is_file():
                        relative = local.relative_to(app)
                        assert (contained / relative).is_file(), "DMG missing " + str(relative)
                        assert local.read_bytes() == (contained / relative).read_bytes(), "Stale DMG file: " + str(relative)
                run("codesign", "--verify", "--deep", "--strict", contained)
            finally:
                run("hdiutil", "detach", directory)
        print("SHA256", hashlib.sha256(image.read_bytes()).hexdigest(), image.name)
    print("PASS artifact gate (ad-hoc signature is not Apple notarization)", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["source", "test", "artifact", "all"], default="all", nargs="?")
    parser.add_argument("--dmg")
    args = parser.parse_args()
    if args.stage in ("source", "all"): source_gate()
    if args.stage in ("test", "all"): tests()
    if args.stage in ("artifact", "all"): artifact_gate(args.dmg)
