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
    quality = checkpoint_file[checkpoint_file.index("struct CalibrationQuality:"):checkpoint_file.index("struct CalibrationConditions:")]
    conditions = checkpoint_file[checkpoint_file.index("struct CalibrationConditions:"):checkpoint_file.index("struct CalibrationPhaseEvent:")]
    export = checkpoint_file[checkpoint_file.index("struct CalibrationPhaseEvent:"):checkpoint_file.index("/// Result of one completed")]
    record = checkpoint_file[checkpoint_file.index("struct CalibrationRecord:"):checkpoint_file.index("/// Weighted blend")]
    swift = "import Foundation\n" + policy + checkpoint + quality + conditions + export + record + validation
    swift += (ROOT / "Sources/Core/ControlResult.swift").read_text()
    swift += (ROOT / "Sources/Core/CalibrationMath.swift").read_text()
    history = (ROOT / "Sources/Core/HistoryStore.swift").read_text()
    alerts = (ROOT / "Sources/Core/AnomalyAlerts.swift").read_text()
    swift += alerts[alerts.index("struct AnomalyRule {"):alerts.index("struct AnomalyEvidence:")]
    swift += history[history.index("struct DailyStat:"):history.index("final class DailyHistory:")]
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
let phases: Set<String> = ["chargingToFull", "discharging", "rechargingToFull", "holdingAtFull", "dischargingToBuffer"]
func quality(_ complete: Bool, _ span: Int, _ issues: Set<String>, _ samples: Int = 100) -> CalibrationQuality {
    CalibrationQuality.evaluate(phases: phases, negativeSamples: samples, positiveSamples: samples, dischargeAh: 3, rechargeAh: 3.1, span: span, issues: issues, backend: "mock", completed: complete)
}
check(quality(true, 80, []).grade == .high, "clean cycle")
check(quality(false, 80, []).grade == .invalid, "incomplete cycle")
check(quality(true, 80, [], 0).grade == .invalid, "no current")
check(quality(true, 20, []).grade == .low, "narrow span")
check(!quality(true, 20, []).eligibleForAggregation, "low grade isolation")
check(quality(true, 80, ["发生过热保护"]).grade == .medium, "thermal event")
let legacyData = try JSONEncoder().encode(CalibrationRecord())
let legacy = try JSONDecoder().decode(CalibrationRecord.self, from: legacyData)
check(legacy.quality == nil, "legacy quality")
check(HealthWindow.delta([]) == nil, "empty trend")
check(HealthWindow.delta([5000]) == nil, "single sample")
check(HealthWindow.delta([5000, 4900]) == -100, "capacity delta")
check(HealthWindow.delta([Double.nan, 0, 5000]) == nil, "invalid values excluded")
check(BatteryTrend.compute(days: []) == nil, "insufficient trend")
let oldDay = DailyStat(day: Date(), temperatureSamples: 1)
check(oldDay.reportedCapacityMAh == nil && oldDay.highTemperatureSeconds == nil, "legacy missing data")
let window = HealthWindow(days: [oldDay], records: [], count: 7)
check(window.highTemperatureHours == nil && window.capacityDelta == nil, "unknown not zero")
let anchor = Date(timeIntervalSinceReferenceDate: 0)
let synthetic = (0..<10).map { (anchor.addingTimeInterval(Double($0) * 7 * 86400), 5000.0 - Double($0) * 7) }
let fit = HealthRegression.fit(synthetic)!
check(abs(fit.changePer30Days + 30) < 1e-8 && fit.rSquared > 0.999, "synthetic known slope")
check(HealthRegression.fit(Array(synthetic.prefix(3))) == nil, "regression minimum samples")
check(HealthRegression.fit((0..<4).map { (anchor, Double(5000 - $0)) }) == nil, "same-day pseudoreplication")
let conditions = CalibrationConditions(model: "test", backend: "bclm", stressMode: "silent", target: 10, startPercentage: 100, meanTemperature: 30, meanPower: 10, designCapacityMAh: 6000)
check(conditions.matches(conditions), "self match")
let mismatch = CalibrationConditions(model: "test", backend: "bclm", stressMode: "silent", target: 10, startPercentage: 100, meanTemperature: 40, meanPower: 10, designCapacityMAh: 6000)
check(!conditions.matches(mismatch), "temperature mismatch")
let exportSample = CalibrationExport.Sample(timestamp: anchor, phase: "discharging", percentage: 80, voltage: 12, amperage: -1, temperature: 30, power: 12)
let package = CalibrationExport(schemaVersion: 1, generatedAt: anchor, completed: false, backend: "mock", helperProtocol: 3, model: "test", capabilities: ["BCLM"], measuredCapacityMAh: nil, measuredCapacityWh: nil, healthPercentage: nil, sampleCount: 1, droppedSamples: 0, quality: nil, conditions: nil, timeline: [], samples: [exportSample])
let exportBytes = try JSONEncoder().encode(package)
let exportObject = try JSONSerialization.jsonObject(with: exportBytes) as! [String: Any]
check(exportObject["samples"] != nil && exportObject["schemaVersion"] != nil, "export schema")
check(exportObject["batterySerial"] == nil && exportObject["reportFilePath"] == nil && exportObject["log"] == nil, "export privacy allowlist")
check(package.csv.split(separator: "\\n").count == 2 && package.csv.contains("Phase"), "CSV sample and header")
for running in [false, true] {
    for recovering in [false, true] {
        check(ControlSafety.ordinaryAllowed(running: running, recovering: recovering) == (!running && !recovering), "control ownership")
    }
}
for current in [0.5, 0.0, -0.01, Double.nan, Double.infinity] {
    check(!ControlSafety.loadAllowed(running: true, dischargePhase: true, current: current, failed: false, waiting: false, hot: false), "no load without discharge evidence")
}
check(ControlSafety.loadAllowed(running: true, dischargePhase: true, current: -1, failed: false, waiting: false, hot: false), "confirmed current")
check(!ControlSafety.loadAllowed(running: true, dischargePhase: true, current: -1, failed: true, waiting: false, hot: false), "failure removes load permission")
check(!ControlSafety.loadAllowed(running: false, dischargePhase: true, current: -1, failed: false, waiting: false, hot: false), "stopped session")
var gate = AnomalyGate()
let rule = AnomalyRule(id: "test", title: "test", duration: 5, cooldown: 20)
gate.beginSample(at: anchor)
check(!gate.evaluate(rule, trigger: true, recover: false, now: anchor), "no spike alert")
gate.beginSample(at: anchor.addingTimeInterval(5))
check(gate.evaluate(rule, trigger: true, recover: false, now: anchor.addingTimeInterval(5)), "sustained alert")
check(!gate.evaluate(rule, trigger: true, recover: false, now: anchor.addingTimeInterval(6)), "cooldown")
gate.ignore("test")
check(!gate.evaluate(rule, trigger: true, recover: false, now: anchor.addingTimeInterval(30)), "ignore episode")
_ = gate.evaluate(rule, trigger: false, recover: true, now: anchor.addingTimeInterval(31))
check(!gate.evaluate(rule, trigger: true, recover: false, now: anchor.addingTimeInterval(32)), "fresh episode duration")
gate.beginSample(at: anchor.addingTimeInterval(100))
check(!gate.evaluate(rule, trigger: true, recover: false, now: anchor.addingTimeInterval(100)), "gap resets evidence")
print("PASS pure policy/math/checkpoint/helper-validation/quality/trend/anomaly tests (no hardware)")
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
