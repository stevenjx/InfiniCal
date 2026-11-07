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
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def ui_lint():
    """Design-token ratchet: font/colour/radius/padding counts may only go down.

    Run as a separate process so the lint stays usable on its own
    (`python3 Tools/ui_lint.py --list`) and cannot import app state by accident.
    """
    result = subprocess.run([sys.executable, str(ROOT / "Tools/ui_lint.py")],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
        raise SystemExit("ui_lint failed")
    print(result.stdout.strip(), flush=True)


def contrast():
    """WCAG check on the palette declared in Theme.swift.

    Parsed from the Swift rather than duplicated here, so editing a colour
    cannot leave the check passing against a stale copy.
    """
    result = subprocess.run([sys.executable, str(ROOT / "Tools/contrast_check.py")],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
        raise SystemExit("contrast check failed")
    print(result.stdout.strip().splitlines()[-1], flush=True)


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
    # Sparkle wiring: the feed must be HTTPS, the public key must be a 32-byte
    # base64 Ed25519 key, and the framework must be vendored for both builders.
    feed = info["SUFeedURL"]
    assert feed.startswith("https://"), "SUFeedURL must use HTTPS"
    assert "appcast" in feed, "SUFeedURL should point at an appcast"
    key = info["SUPublicEDKey"]
    assert info.get("SUEnableAutomaticChecks") is False, "Auto checks must default off"
    assert info.get("SUAllowsAutomaticUpdates") is False, "Silent installs must stay off"
    import base64
    assert len(base64.b64decode(key)) == 32, "SUPublicEDKey must be a 32-byte Ed25519 key"
    assert (ROOT / "Vendor/Sparkle.framework").is_dir(), "Sparkle.framework not vendored"
    for builder in ("build.sh", "Tools/generate_xcodeproj.py"):
        assert "Sparkle" in (ROOT / builder).read_text(), builder + " does not link Sparkle"
    run("git", "-C", ROOT, "diff", "--check")
    ui_lint()
    contrast()
    print("PASS source/version/localization gate", flush=True)


def tests():
    models = (ROOT / "Sources/Core/Models.swift").read_text()
    policy = models[models.index("enum ChargePolicy {"):models.index("\nstruct CalibrationRun {")]
    tasks_src = models[models.index("enum TaskKind:"):models.index("struct HistoryPoint:")]
    checkpoint_file = (ROOT / "Sources/Core/CalibrationModel.swift").read_text()
    checkpoint = checkpoint_file[checkpoint_file.index("struct CalibrationCheckpoint:"):checkpoint_file.index("/// One 1 Hz")]
    helper = (ROOT / "Helper/main.swift").read_text()
    validation = helper[helper.index("func isAllowedWriteKey("):helper.index("let allowedExecutables:")]
    quality = checkpoint_file[checkpoint_file.index("struct CalibrationQuality:"):checkpoint_file.index("struct CalibrationConditions:")]
    conditions = checkpoint_file[checkpoint_file.index("struct CalibrationConditions:"):checkpoint_file.index("struct CalibrationPhaseEvent:")]
    export = checkpoint_file[checkpoint_file.index("struct CalibrationPhaseEvent:"):checkpoint_file.index("/// Result of one completed")]
    record = checkpoint_file[checkpoint_file.index("struct CalibrationRecord:"):checkpoint_file.index("enum CalibrationStore {")]
    smc_source = (ROOT / "Sources/Core/SMC.swift").read_text()
    smc_info = smc_source[smc_source.index("struct SMCKeyInfo {"):smc_source.index("enum SMCError:")]
    smc_loads = smc_source[smc_source.index("    fileprivate static func loadU8"):smc_source.index("    // MARK: - Typed helpers")]
    smc_decode = smc_source[smc_source.index("    static func decode("):smc_source.index("    func writeUInt8(")]
    swift = "import Foundation\n" + policy + tasks_src + checkpoint + quality + conditions + export + record
    swift += smc_info + "enum SMCError: Error { case unsupportedType(String) }\nenum SMC {\n" + smc_loads + smc_decode + "}\n" + validation
    write_branch = helper[helper.index('    case "write":'):helper.index('    case "socpower":')]
    swift += '''
final class MockWriteSMC {
    var metadata: [String: SMCKeyInfo] = [:]
    var readings: [String: (SMCKeyInfo, [UInt8])] = [:]
    var writes = 0
    func keyInfo(_ key: String) -> SMCKeyInfo? { metadata[key] }
    func readBytes(_ key: String) throws -> (SMCKeyInfo, [UInt8]) {
        guard let result = readings[key] else { throw SMCError.unsupportedType(key) }
        return result
    }
    func writeBytes(_ key: String, _ bytes: [UInt8]) throws { writes += 1 }
}
let smc = MockWriteSMC()
func handleWrite(_ request: [String: Any]) -> [String: Any] {
    switch request["cmd"] as? String {
''' + write_branch + '''
    default: return ["ok": false]
    }
}
'''
    swift += (ROOT / "Sources/Core/ControlResult.swift").read_text()
    swift += (ROOT / "Sources/Core/DeviceProfile.swift").read_text()
    swift += (ROOT / "Sources/Core/Advice.swift").read_text()
    swift += (ROOT / "Sources/Core/ChargeArbitration.swift").read_text()
    app_state = (ROOT / "Sources/Core/AppState.swift").read_text()
    fan_source = (ROOT / "Sources/Core/FanController.swift").read_text()
    update_methods = app_state[app_state.index("    func prepareForUpdate()"):app_state.index("    private func tick()", app_state.index("    func prepareForUpdate()"))]
    fan_cancel = fan_source[fan_source.index("    func completeUpdateCancellation()"):fan_source.index("    // MARK: - Persistence")]
    fan_properties = fan_source[fan_source.index("    @Published var modes:"):fan_source.index("    @Published var curveSensorKey:")].replace("@Published ", "").replace("UserDefaults.standard", "defaults")
    swift += '''
// 只抽取生产入口与成功取消方法；所有外部依赖均为内存桩。
func t(_ text: String) -> String { text }
func tf(_ text: String, _ values: String...) -> String {
    var result = text
    for value in values {
        guard let range = result.range(of: "{p}") else { break }
        result.replaceSubrange(range, with: value)
    }
    return result
}
struct TestCapabilities { var hasHelper = false; var protocolVersion = 0; var features: Set<String> = [] }
final class HelperClient {
    static let shared = HelperClient()
    var available = false
    var protocolVersion = 0
    var features: Set<String> = []
    var refreshes = 0
    func refreshInstallState() -> Bool { refreshes += 1; return available }
}
final class ChargeController {
    static let shared = ChargeController()
    var adapterRestoreError: String?
    var chargeFails = false
    var scans = 0
    func detectCapabilities() -> TestCapabilities {
        scans += 1
        return TestCapabilities(hasHelper: HelperClient.shared.available,
                                protocolVersion: HelperClient.shared.protocolVersion,
                                features: HelperClient.shared.features)
    }
    func stopHoldingCeiling() {}
    func restoreAdapterLeftOff() {}
    func endForcedDischarge() {}
    func prepareForFullCharge() throws {
        check(FanController.shared.updateSuspended, "充电清理期间风扇仍暂停")
        if chargeFails { throw NSError(domain: "charge", code: 1) }
    }
}
final class TestCalibration {
    var isRunning = false
    var needsRecovery = false
    var suspended = false
    var resumes = 0
    func prepareIdleForUpdate() { suspended = true }
    func resumeAfterUpdateCancellation() { suspended = false; resumes += 1 }
}
enum FanMode { case auto, fixed, full }
struct TestFan { let index: Int }
final class TestDefaults {
    var curve = true
    func set(_ value: Bool, forKey: String) { curve = value }
}
final class FanController {
    static let shared = FanController()
    enum Keys { static let curveEnabled = "curve" }
    let defaults = TestDefaults()
    var persistedModes: [Int: FanMode] = [:]
    func persistModes() { persistedModes = modes }
''' + fan_properties + '''
    var fans = [TestFan(index: 0), TestFan(index: 1)]
    var sessionCooling = true
    var modesBeforeSession: [Int: FanMode] = [0: .full]
    var lastAppliedFixed = [0: 4000]
    var lastCurveWrite = [0: 4000]
    var lastCurveTemperature: Double? = 80
    var activePresetName: String?
    var updateSuspended = false
    var lastError: String? = "fan"
    var restoreFails = false
    var restores = 0
    var curveWrites = 0
    func applyCurveIfNeeded(force: Bool) {
        if !updateSuspended && (curveEnabled || sessionCooling) { curveWrites += 1 }
    }
    func restoreSystemControl() -> Bool {
        check(updateSuspended, "风扇清理期间保持暂停")
        restores += 1
        return !restoreFails
    }
''' + fan_cancel + '''
}
final class TestAppState {
    let calibrationEngine = TestCalibration()
    var updatePreparationActive = false
    var helperInstalled = true
    var capabilities = TestCapabilities()
    var lastAppliedLimit: Int? = 80
    var lastChargingAllowed: Bool? = false
''' + update_methods + '''
}
let updateApp = TestAppState()
let updateFan = FanController.shared
let updateHelper = HelperClient.shared
let updateCharge = ChargeController.shared
func checkPaused() {
    check(updateApp.updatePreparationActive && updateFan.updateSuspended && updateApp.calibrationEngine.suspended,
          "失败时三个门禁必须保持暂停")
    check(updateApp.calibrationEngine.resumes == 0, "失败不可恢复校准入口")
}
updateFan.modes = [0: .fixed, 1: .full, 7: .full]
updateFan.curveEnabled = true
check(updateApp.prepareForUpdate() != nil, "不能使用缓存的 helperInstalled=true")
checkPaused()
check(!updateApp.helperInstalled && updateHelper.refreshes == 1 && updateCharge.scans == 1, "首次准备主动刷新")
updateHelper.available = true
updateHelper.protocolVersion = 3
updateHelper.features = ["inflow"]
updateCharge.adapterRestoreError = "adapter"
check(updateApp.cancelUpdatePreparation() == "adapter", "适配器失败返回 UI 错误")
checkPaused()
updateCharge.adapterRestoreError = nil
updateCharge.chargeFails = true
check(updateApp.cancelUpdatePreparation() != nil, "充电清理失败阻止取消")
checkPaused()
updateCharge.chargeFails = false
updateFan.restoreFails = true
check(updateApp.cancelUpdatePreparation() == "fan", "风扇失败阻止取消")
checkPaused()
check(updateFan.modes[0] == .fixed && updateFan.curveEnabled, "失败不提交自动策略")
updateFan.restoreFails = false
updateHelper.protocolVersion = 4
updateHelper.features = ["inflow", "new"]
check(updateApp.prepareForUpdate() == nil, "暂停期间重试可成功")
checkPaused()
check(updateApp.capabilities.protocolVersion == 4 && updateApp.capabilities.features.contains("new"), "同为已安装也重扫协议能力")
check(updateApp.cancelUpdatePreparation() == nil, "失败后取消重试成功")
check(!updateApp.updatePreparationActive && !updateFan.updateSuspended && !updateApp.calibrationEngine.suspended, "成功后解除门禁")
check(updateApp.lastAppliedLimit == nil && updateApp.lastChargingAllowed == nil, "清除充电应用缓存")
check(updateFan.modes.values.allSatisfy { $0 == .auto } && updateFan.modes.count == 3, "所有已知风扇同步自动")
check(updateFan.persistedModes == updateFan.modes && !updateFan.defaults.curve && !updateFan.curveEnabled, "didSet 持久化自动与关闭曲线")
check(!updateFan.sessionCooling && updateFan.modesBeforeSession.isEmpty && updateFan.lastAppliedFixed.isEmpty && updateFan.lastCurveWrite.isEmpty && updateFan.lastCurveTemperature == nil, "清除重放缓存")
let cancelCounts = [updateHelper.refreshes, updateCharge.scans, updateFan.restores, updateApp.calibrationEngine.resumes]
updateFan.modes[0] = .full
check(updateApp.cancelUpdatePreparation() == nil, "连续取消幂等")
check(cancelCounts == [updateHelper.refreshes, updateCharge.scans, updateFan.restores, updateApp.calibrationEngine.resumes] && updateFan.modes[0] == .full, "重复取消不清理、不覆盖之后手动选择")
// 排空真实 curveEnabled.didSet 排队的回调，取消成功后也不能重启曲线。
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
check(updateFan.curveWrites == 0, "didSet 异步回调不会绕过安全自动策略")
updateHelper.available = false
check(updateApp.prepareForUpdate() != nil && !updateApp.capabilities.hasHelper, "helper 消失时再次刷新并拒绝")
check(updateHelper.refreshes == updateCharge.scans, "每次尝试都刷新安装状态与能力")
print("PASS update retry/cancellation transitions and fan persistence (no hardware)")
'''
    swift += (ROOT / "Sources/Core/CalibrationMath.swift").read_text()
    engine = (ROOT / "Sources/Core/CalibrationEngine.swift").read_text()
    swift += engine[engine.index("enum CalibrationPreset:"):engine.index("\n// MARK: - Engine")]
    history = (ROOT / "Sources/Core/HistoryStore.swift").read_text()
    alerts = (ROOT / "Sources/Core/AnomalyAlerts.swift").read_text()
    swift += alerts[alerts.index("struct AnomalyRule {"):alerts.index("struct AnomalyEvidence:")]
    swift += history[history.index("struct DailyStat:"):history.index("final class DailyHistory:")]
    # StoreIO and LowPower are pure value types over the filesystem and clocks,
    # so the recovery and estimation rules can be exercised without a battery.
    swift += (ROOT / "Sources/Core/StoreIO.swift").read_text()
    swift += (ROOT / "Sources/Core/LowPower.swift").read_text()
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
func metadata(_ type: String, _ size: UInt32, _ writable: Bool = true) -> SMCKeyInfo {
    SMCKeyInfo(size: size, type: type, attributes: writable ? 0x40 : 0)
}
func floatBytes(_ value: Float) -> [UInt8] {
    var bits = value.bitPattern
    return withUnsafeBytes(of: &bits) { Array($0) }
}
func native16(_ value: UInt16) -> [UInt8] {
    var raw = value
    return withUnsafeBytes(of: &raw) { Array($0) }
}
let fanReadings: [String: Double] = ["FNum": 2, "F0Mn": 1000, "F0Mx": 6000]
func accepts(_ key: String, _ type: String, _ size: UInt32, _ bytes: [UInt8],
             _ readings: [String: Double] = fanReadings) -> Bool {
    WriteValidation.accepts(key: key, info: metadata(type, size), bytes: bytes, read: { readings[$0] })
}
for (key, allowed) in [("CH0B", [0, 2]), ("CH0C", [0, 2]), ("CHIE", [0, 8]),
                       ("CH0I", [0, 1]), ("CH0J", [0, 1]), ("BCLM", Array(0...100))] {
    for value in 0...255 {
        check(accepts(key, "ui8 ", 1, [UInt8(value)]) == allowed.contains(value), "byte value domain")
    }
    check(!accepts(key, "si8 ", 1, [0]), "wrong byte type")
    check(!accepts(key, "ui8 ", 2, [0, 0]), "wrong byte width")
}
for value in 0...255 {
    check(accepts("CHTE", "ui32", 4, [UInt8(value), 0, 0, 0]) == (value <= 1), "CHTE low mask")
}
for index in 1...3 {
    var payload: [UInt8] = [0, 0, 0, 0]; payload[index] = 1
    check(!accepts("CHTE", "ui32", 4, payload), "CHTE other bits")
}
check(!accepts("CHTE", "flt ", 4, [0, 0, 0, 0]), "CHTE type")
for value in 0...65535 {
    check(accepts("FS! ", "ui16", 2, [UInt8(value >> 8), UInt8(value & 255)]) == (value & ~5 == 0), "FS known mode bits")
}
check(accepts("FS! ", "ui16", 2, [0, 0], [:]), "FS zero recovery without count")
for count in [Double.nan, .infinity, -1, 1.5, 9] {
    check(!accepts("FS! ", "ui16", 2, [0, 1], ["FNum": count]), "invalid fan count")
}
check(!accepts("FS! ", "fpe2", 2, [0, 0]), "FS type")
for value in 0...255 {
    check(accepts("F0Md", "ui8 ", 1, [UInt8(value)]) == (value <= 1), "fan mode values")
}
check(!accepts("F2Md", "ui8 ", 1, [1]), "unknown fan index")
check(!accepts("F0Md", "si8 ", 1, [0]), "mode type")
for value: Float in [0, 999, 1000, 3000, 6000, 6001, -1, .nan, .infinity, -.infinity] {
    check(accepts("F0Tg", "flt ", 4, floatBytes(value)) == (value.isFinite && value >= 1000 && value <= 6000), "float bounds and finite")
}
for value: UInt16 in [0, 3999, 4000, 12000, 24000, 24001, 65535] {
    check(accepts("F0Tg", "fpe2", 2, native16(value)) == (value >= 4000 && value <= 24000), "fpe2 uses actual SMC decoder")
}
check(accepts("F0Tg", "ui8 ", 1, [100], ["FNum": 1, "F0Mn": 0, "F0Mx": 255]), "existing ui8 encoder")
check(accepts("F0Tg", "ui16", 2, native16(3000)), "existing ui16 encoder")
let appFpe2: [UInt8] = [UInt8(12000 >> 8), UInt8(12000 & 255)]
let decodedAppFpe2 = try SMC.decode(info: metadata("fpe2", 2), bytes: appFpe2)
check(accepts("F0Tg", "fpe2", 2, appFpe2) == (decodedAppFpe2 >= 1000 && decodedAppFpe2 <= 6000), "App big-endian fpe2 is validated by actual decoder, not guessed")
for (type, width) in [("flt ", 4), ("fpe2", 2), ("ui16", 2), ("ui8 ", 1)] {
    for size in [0, 1, 2, 3, 4, 5] where size != width {
        check(WriteValidation.numeric(info: metadata(type, UInt32(size)), bytes: Array(repeating: 0, count: size)) == nil, "hardware read metadata width")
    }
}
check(!accepts("F0Tg", "si32", 4, floatBytes(3000)), "unsupported target type")
check(accepts("F0Tg", "flt ", 4, floatBytes(0), ["FNum": 1, "F0Mn": 0, "F0Mx": 6000]), "zero only with zero minimum")
for bounds: [String: Double] in [[:], ["FNum": 1], ["FNum": 1, "F0Mn": 1000],
    ["FNum": 1, "F0Mn": .nan, "F0Mx": 6000], ["FNum": 1, "F0Mn": 0, "F0Mx": .infinity],
    ["FNum": 1, "F0Mn": -1, "F0Mx": 6000], ["FNum": 1, "F0Mn": 7000, "F0Mx": 6000],
    ["FNum": 1, "F0Mn": 0, "F0Mx": 0]] {
    check(!accepts("F0Tg", "flt ", 4, floatBytes(3000), bounds), "missing or invalid bounds fail closed")
}
for key in ["CHWA", "ACEN", "F0Ac", "XXXX"] {
    check(!accepts(key, "ui8 ", 1, [0]), "no whitelist expansion")
}
for key in ["CH0B", "CHTE", "FS! ", "F0Md", "F0Tg"] {
    let type = key == "CHTE" ? "ui32" : (key == "FS! " ? "ui16" : (key == "F0Tg" ? "flt " : "ui8 "))
    let width: UInt32 = type == "ui32" || type == "flt " ? 4 : (type == "ui16" ? 2 : 1)
    for size: UInt32 in [0, 1, 2, 3, 4, 5, 33] where size != width {
        check(!accepts(key, type, size, Array(repeating: 0, count: Int(size))), "declared width mismatch")
    }
    check(!accepts(key, type, width, []), "short payload")
    check(!accepts(key, type, width, Array(repeating: 0, count: Int(width) + 1)), "long payload")
    check(!WriteValidation.accepts(key: key, info: metadata(type, width, false), bytes: Array(repeating: 0, count: Int(width)), read: { fanReadings[$0] }), "read-only")
}
check(WriteValidation.payload("00aAfF") == [0, 170, 255], "hex valid")
for value: Any in [true, false, NSNumber(value: 1.5), NSNumber(value: -1), 256, [true], [1.5], [-1], [256], NSNull(), "", "0", "-1", "+1", "gg", " 0", "００", String(repeating: "00", count: 33)] {
    check(WriteValidation.payload(value) == nil, "no JSON coercion or malformed hex")
}
for json in ["true", "false", "1.5", "-1", "256", "[true]", "[1.5]", "[-1]", "[256]", "null"] {
    let object = try JSONSerialization.jsonObject(with: Data(("{\\"bytes\\":" + json + "}").utf8)) as! [String: Any]
    check(WriteValidation.payload(object["bytes"]) == nil, "JSON NSNumber coercion rejected")
}
smc.metadata["CH0B"] = metadata("ui8 ", 1)
check(handleWrite(["cmd": "write", "key": "CH0B", "bytes": "02"])["ok"] as? Bool == true && smc.writes == 1, "valid handler writes once")
for payload: Any in ["01", "0000", true, -1, 1.5, [256]] {
    check(handleWrite(["cmd": "write", "key": "CH0B", "bytes": payload])["ok"] as? Bool == false, "handler rejects")
}
smc.metadata["CH0B"] = metadata("si8 ", 1)
_ = handleWrite(["cmd": "write", "key": "CH0B", "bytes": "00"])
smc.metadata["F0Tg"] = metadata("flt ", 4)
_ = handleWrite(["cmd": "write", "key": "F0Tg", "bytes": "00000000"])
check(smc.writes == 1, "all rejected handler requests perform zero SMC writes")
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
// P2-02 calibration presets: depth is a separate axis from load intensity.
check(CalibrationPreset.quickCheck.dischargeTarget == 50, "quick check stops at 50%")
check(CalibrationPreset.standard.dischargeTarget == 20, "standard stops at 20%")
check(CalibrationPreset.deep.dischargeTarget == 10, "deep stops at 10%")
check(CalibrationPreset.quickCheck.capsQualityAtLow, "quick check caps quality")
check(!CalibrationPreset.standard.capsQualityAtLow && !CalibrationPreset.deep.capsQualityAtLow,
      "only the quick check is capped")
check(CalibrationPreset.deep.requiresExplicitUserAction, "deep never starts implicitly")
check(!CalibrationPreset.standard.requiresExplicitUserAction
      && !CalibrationPreset.quickCheck.requiresExplicitUserAction,
      "standard and quick may start from automation")
let capped = CalibrationQuality.evaluate(phases: phases, negativeSamples: 100, positiveSamples: 100,
    dischargeAh: 3, rechargeAh: 3.1, span: 80, issues: [], backend: "mock",
    completed: true, presetCapped: true)
check(capped.grade == .low, "quick check cannot grade above low")
check(capped.reasons.contains("快速检查模式，未做完整深度放电"), "quick check explains the cap")
check(!capped.eligibleForAggregation, "quick check stays out of the health average")
let uncapped = CalibrationQuality.evaluate(phases: phases, negativeSamples: 100, positiveSamples: 100,
    dischargeAh: 3, rechargeAh: 3.1, span: 80, issues: [], backend: "mock", completed: true)
check(uncapped.grade == .high, "full depth is unaffected by the cap")
let cpPreset = CalibrationCheckpoint(sessionID: UUID(), phase: "discharging", startedAt: Date(),
    lastSampleAt: Date(), targetPercentage: 20, restoreLimit: 80, stressMode: "balanced",
    adapterControl: nil, chargeControl: "bclm", reason: "test", preset: "quickCheck")
let cpBytes = try JSONEncoder().encode(cpPreset)
check(try JSONDecoder().decode(CalibrationCheckpoint.self, from: cpBytes).preset == "quickCheck",
      "preset survives the recovery journal")
let cpLegacy = CalibrationCheckpoint(sessionID: UUID(), phase: "idle", startedAt: Date(),
    lastSampleAt: Date(), targetPercentage: 20, restoreLimit: 80, stressMode: "silent",
    adapterControl: nil, chargeControl: "bclm", reason: "legacy")
check(try JSONDecoder().decode(CalibrationCheckpoint.self,
      from: try JSONEncoder().encode(cpLegacy)).preset == nil, "legacy journal without preset still decodes")
// P2-01 power attribution: ps reports 100% per core, so the share of the whole
// CPU is the percentage over (100 × cores).
let halfCore = PowerAttribution.attribute(cpuPercent: 50, cores: 10, cpuWatts: 10,
                                          currentWatts: 20, fullCapacityHours: 5)
check(halfCore.watts == 0.5, "half a core of ten gets 5% of CPU watts")
check(halfCore.gainMinutes > 0, "closing a load buys battery minutes")
let oneCore = PowerAttribution.attribute(cpuPercent: 100, cores: 10, cpuWatts: 10,
                                         currentWatts: 20, fullCapacityHours: 5)
check(oneCore.watts == 1.0, "one full core of ten gets 10%")
check(oneCore.gainMinutes > halfCore.gainMinutes, "a bigger load buys more minutes")
// Attribution needs a measurement and a battery estimate; without either it
// must report zero rather than invent a figure.
let noCPUWatts = PowerAttribution.attribute(cpuPercent: 100, cores: 10, cpuWatts: 0,
                                            currentWatts: 20, fullCapacityHours: 5)
check(noCPUWatts == PowerAttribution.Result(watts: 0, gainMinutes: 0), "no CPU measurement means no claim")
let onAC = PowerAttribution.attribute(cpuPercent: 100, cores: 10, cpuWatts: 10,
                                      currentWatts: 20, fullCapacityHours: nil)
check(onAC.watts == 0 && onAC.gainMinutes == 0, "on AC no battery minutes are claimed")
// The load cannot exceed the total draw, and the runtime must stay finite.
let absurd = PowerAttribution.attribute(cpuPercent: 100, cores: 1, cpuWatts: 100,
                                        currentWatts: 1, fullCapacityHours: 5)
check(absurd.watts == 100, "share is capped at the whole CPU")
check(absurd.gainMinutes >= 0 && absurd.gainMinutes < 100_000, "runtime stays bounded")
let subPixel = PowerAttribution.attribute(cpuPercent: 0.01, cores: 8, cpuWatts: 8,
                                          currentWatts: 20, fullCapacityHours: 5)
check(subPixel.watts > 0 && subPixel.watts < 0.001, "a tiny load still attributes a tiny share")
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
var restoredFans: [Int] = []
let partialFanFailure = FanRecovery.restore(count: 2) { index in
    restoredFans.append(index)
    if index == 0 { throw NSError(domain: "mock-write", code: 1) }
}
check(restoredFans == [0, 1] && partialFanFailure.count == 1 && partialFanFailure[0].hasPrefix("F0:"), "partial failure attempts every declared fan")
check(FanRecovery.restore(count: 2) { _ in }.isEmpty, "all declared fans verified")
check(!FanRecovery.restore(count: 2) { index in
    if index == 1 { throw NSError(domain: "mock-readback", code: 2) }
}.isEmpty, "unverified second fan blocks recovery")
var unknownFanWrites = 0
check(!FanRecovery.restore(count: nil) { _ in unknownFanWrites += 1 }.isEmpty && unknownFanWrites == 0, "unknown count is not fanless")
check(FanRecovery.restore(count: 0) { _ in fatalError("fanless write") }.isEmpty, "confirmed fanless")
check(!FanRecovery.restore(count: 9) { _ in fatalError("invalid count write") }.isEmpty, "invalid fan count")
// P0-01 unified control journal: one place for charge, fan and sleep results.
let journal = ControlJournal.shared
journal.clear()
let stamp = Date(timeIntervalSince1970: 1_000)
journal.record(ControlEvidence(operation: "fan.mode", backend: "smc", phase: .accepted,
                               target: "F0 2000 rpm", observed: "Md=manual", date: stamp))
check(journal.entries.count == 1, "journal records a control result")
check(journal.latest("fan.mode")?.phase == .accepted, "latest returns the newest entry")
// A held ceiling is rewritten every 400 ms; the same state must not repeat.
journal.record(ControlEvidence(operation: "fan.mode", backend: "smc", phase: .accepted,
                               target: "F0 2000 rpm", observed: "Md=manual",
                               date: stamp.addingTimeInterval(1)))
check(journal.entries.count == 1, "identical state collapses instead of flooding")
// A phase change is new information and must be kept.
journal.record(ControlEvidence(operation: "fan.mode", backend: "smc", phase: .verified,
                               target: "F0 2000 rpm", observed: "Md=manual", date: stamp.addingTimeInterval(2)))
check(journal.entries.count == 2, "phase change appends a new entry")
check(journal.entries.first?.phase == .verified, "newest entry is first")
// A new target is also new information.
journal.record(ControlEvidence(operation: "fan.mode", backend: "smc", phase: .verified,
                               target: "F0 3000 rpm", observed: "Md=manual", date: stamp.addingTimeInterval(3)))
check(journal.entries.count == 3, "target change appends a new entry")
// Sleep and charge write to the same journal, so one question has one answer.
journal.record(ControlEvidence(operation: "sleep.system", backend: "iokit", phase: .verified,
                               target: "prevent idle sleep", date: stamp.addingTimeInterval(4)))
journal.record(ControlEvidence(operation: "chargeLimit", backend: "bclm", phase: .failed,
                               target: "80%", detail: "read-back 95%", date: stamp.addingTimeInterval(5)))
check(journal.entries.count == 5, "all controllers share one journal")
check(journal.latest("chargeLimit")?.phase == .failed, "a failed write stays failed")
check(journal.latest("sleep.system")?.backend == "iokit", "sleep results keep their backend")
// Bounded: hardware control runs at up to 2.5 Hz, so the log cannot grow forever.
journal.clear()
for index in 0..<80 {
    journal.record(ControlEvidence(operation: "pulse", backend: "smc", phase: .accepted,
                                   target: "t\\(index)", date: stamp.addingTimeInterval(Double(index))))
}
check(journal.entries.count == 60, "journal is bounded")
check(journal.entries.first?.target == "t79", "bound keeps the newest entries")
check(journal.entries.last?.target == "t20", "bound drops the oldest entries")
journal.clear()
check(journal.entries.isEmpty, "clear empties the journal")
// Every phase has distinct wording: the UI must never show a raw case name.
let phaseLabels = [ControlPhase.requested, .accepted, .verified, .active,
                   .failed, .expired, .restored].map { $0.label }
check(Set(phaseLabels).count == phaseLabels.count, "each phase has its own label")
check(!phaseLabels.contains("requested"), "labels are human wording, not case names")
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
// MARK: - 定时任务：优先级、冲突、条件与手动覆盖
let taskBase = Date(timeIntervalSince1970: 1_700_000_000)
func makeTask(_ kind: TaskKind, hour: Int = 9, minute: Int = 0,
              conditions: TaskConditions? = nil) -> ScheduledTask {
    var task = ScheduledTask(kind: kind, value: 80, hour: hour, minute: minute, weekdays: Set(1...7))
    task.conditions = conditions
    return task
}
let taskCtx = TaskContext(percentage: 50, temperature: 30, onAdapter: true,
                          manualOverride: nil, now: taskBase)

check(TaskPolicy.rank(.stopCharging) < TaskPolicy.rank(.startDischarge), "stopping outranks draining")
check(TaskPolicy.rank(.startDischarge) < TaskPolicy.rank(.calibrate), "draining outranks calibration")
check(TaskPolicy.rank(.calibrate) < TaskPolicy.rank(.setLimit), "calibration outranks a ceiling")
check(TaskPolicy.rank(.setLimit) < TaskPolicy.rank(.topUp), "a ceiling outranks a top-up")
check(TaskPolicy.lever(.topUp) == TaskPolicy.lever(.calibrate), "top-up and calibration share a lever")
check(TaskPolicy.lever(.stopCharging) == TaskPolicy.lever(.startDischarge), "pause and discharge share a lever")
check(TaskPolicy.lever(.stopCharging) == TaskPolicy.lever(.topUp), "stopping and topping up fight over the same lever")
check(TaskPolicy.lever(.setLimit) != TaskPolicy.lever(.topUp), "a ceiling and a top-up touch different levers")

let taskClash = TaskPolicy.decide([makeTask(.topUp), makeTask(.stopCharging)], context: taskCtx)
check(taskClash.count == 2, "every due task gets a decision")
check(taskClash[0].task.kind == .stopCharging, "the safety task runs first")
check(taskClash[0].verdict == .run, "the winner runs")
if case .skipped(let clashReason) = taskClash[1].verdict {
    check(clashReason.contains("暂停充电"), "skip reason names the winner")
} else {
    check(false, "a conflicting task must be skipped")
}

let taskBoth = TaskPolicy.decide([makeTask(.topUp), makeTask(.setLimit)], context: taskCtx)
check(taskBoth.count == 2, "both decisions present")
check(taskBoth[0].verdict == .run && taskBoth[1].verdict == .run, "different levers both run")
check(taskBoth[0].task.kind == .setLimit, "the ceiling is applied before the top-up that restores it")

let belowOnly = TaskConditions(onlyBelowPercentage: 40, onlyOnAdapter: nil, maxTemperature: nil)
let heldTask = TaskPolicy.decide([makeTask(.topUp, conditions: belowOnly)], context: taskCtx)
if case .skipped(let belowReason) = heldTask[0].verdict {
    check(belowReason.contains("40"), "battery condition names the threshold")
} else {
    check(false, "battery condition must hold the task")
}
var lowCtx = taskCtx
lowCtx.percentage = 20
check(TaskPolicy.decide([makeTask(.topUp, conditions: belowOnly)], context: lowCtx)[0].verdict == .run,
      "battery condition passes when low enough")

let heatLimit = TaskConditions(onlyBelowPercentage: nil, onlyOnAdapter: nil, maxTemperature: 35)
var hotCtx = taskCtx
hotCtx.temperature = 41
if case .skipped(let heatReason) = TaskPolicy.decide([makeTask(.topUp, conditions: heatLimit)], context: hotCtx)[0].verdict {
    check(heatReason.contains("35"), "heat condition names the ceiling")
} else {
    check(false, "heat condition must hold the task")
}

let adapterOnly = TaskConditions(onlyBelowPercentage: nil, onlyOnAdapter: true, maxTemperature: nil)
var unplugged = taskCtx
unplugged.onAdapter = false
if case .skipped = TaskPolicy.decide([makeTask(.topUp, conditions: adapterOnly)], context: unplugged)[0].verdict {
    check(true, "adapter condition blocks when unplugged")
} else {
    check(false, "adapter condition blocks when unplugged")
}
check(TaskPolicy.decide([makeTask(.topUp, conditions: adapterOnly)], context: taskCtx)[0].verdict == .run,
      "adapter condition passes when plugged in")

var manualCtx = taskCtx
manualCtx.manualOverride = TaskContext.ManualOverride(kind: .stopCharging,
                                                      at: taskBase.addingTimeInterval(-600))
if case .skipped(let manualReason) = TaskPolicy.decide([makeTask(.topUp)], context: manualCtx)[0].verdict {
    check(manualReason.contains("10"), "manual override names how long ago")
} else {
    check(false, "a manual pause must block a scheduled top-up")
}
var staleCtx = taskCtx
staleCtx.manualOverride = TaskContext.ManualOverride(
    kind: .stopCharging, at: taskBase.addingTimeInterval(-TaskPolicy.manualOverrideWindow - 60))
check(TaskPolicy.decide([makeTask(.topUp)], context: staleCtx)[0].verdict == .run,
      "the override window expires")

var otherLever = taskCtx
otherLever.manualOverride = TaskContext.ManualOverride(kind: .setLimit, at: taskBase.addingTimeInterval(-60))
check(TaskPolicy.decide([makeTask(.topUp)], context: otherLever)[0].verdict == .run,
      "a manual ceiling does not block a top-up")

let three = [makeTask(.setLimit), makeTask(.stopCharging), makeTask(.topUp)]
let forward = TaskPolicy.decide(three, context: taskCtx).map { $0.task.kind }
let backward = TaskPolicy.decide(Array(three.reversed()), context: taskCtx).map { $0.task.kind }
check(forward == backward, "decision order does not depend on input order")
check(TaskPolicy.decide([makeTask(.topUp)], context: taskCtx).count == 1, "a single task gets one decision")

let legacyLog = TaskLogEntry(title: "充满", detail: "09:00")
let legacyRoundTrip = (try? JSONEncoder().encode(legacyLog)).flatMap { try? JSONDecoder().decode(TaskLogEntry.self, from: $0) }
check(legacyRoundTrip?.outcome == nil, "history entries written before outcomes still decode")
// MARK: - 跨机型能力画像：匹配、优先级、去重与回滚
let ruleLibrary = CapabilityRuleLibrary.bundled
check(ruleLibrary.validationError == nil, "内置规则库必须自洽")
check(ChipFamily.classify("Apple M2 Pro") == .appleSilicon, "Apple 芯片归类为 Apple Silicon")
check(ChipFamily.classify("Intel(R) Core(TM) i9-9880H") == .intel, "Intel 品牌串归类为 Intel")
check(ChipFamily.classify("--") == .unknown, "读不到品牌串时归类为未知")

let laptop = DeviceProfile(model: "Mac14,9", chip: "Apple M2 Pro", family: .appleSilicon,
                           macOSMajor: 27, chargeStrategy: "systemLimit", helperAvailable: true,
                           fanCount: 2, hasBattery: true, sensorKeys: ["Tp01"])
let laptopAssessment = ruleLibrary.assess(laptop)
check(laptopAssessment.ruleIDs.contains("system-limit-floor-80"), "macOS 26+ 命中系统上限下限规则")
check(laptopAssessment.ruleIDs.contains("system-limit-preferred"), "系统上限优先建议出现")
check(!laptopAssessment.ruleIDs.contains("bclm-readback"), "系统上限机器不应命中 BCLM 规则")
check(!laptopAssessment.ruleIDs.contains("intel-no-socpower"), "Intel 规则不应命中 Apple Silicon")
check(laptopAssessment.notes.isEmpty, "正常笔记本没有本机实测告警")
check(laptopAssessment.libraryVersion == ruleLibrary.version, "评估记录所用规则库版本")

// 更具体的规则必须排在前面：机型规则优先于通用建议。
let fanless = DeviceProfile(model: "Mac14,2", chip: "Apple M2", family: .appleSilicon,
                            macOSMajor: 27, chargeStrategy: "systemLimit", helperAvailable: true,
                            fanCount: 0, hasBattery: true, sensorKeys: [])
let fanlessAssessment = ruleLibrary.assess(fanless)
check(fanlessAssessment.ruleIDs.first == "fanless-air", "机型专属规则排在最前")
check(fanlessAssessment.limitations.contains("该机型为无风扇设计，没有可控制的风扇。"), "无风扇限制被列出")
check(fanlessAssessment.notes.contains("未检测到风扇：风扇控制不适用。"), "风扇事实来自实测而非规则")
check(fanlessAssessment.notes.contains("没有读到温度传感器：温控与热保护无法生效。"), "缺少传感器时给出实测提示")

// 台式机：规则说没有电池，实测也同样说没有电池，两者互不替代。
let desktop = DeviceProfile(model: "Macmini9,1", chip: "Apple M1", family: .appleSilicon,
                            macOSMajor: 27, chargeStrategy: "unavailable", helperAvailable: true,
                            fanCount: 1, hasBattery: false, sensorKeys: [])
let desktopAssessment = ruleLibrary.assess(desktop)
check(desktopAssessment.ruleIDs.contains("desktop-no-battery"), "台式机型命中无电池规则")
check(desktopAssessment.notes.contains("未检测到电池：充电控制、校准与电池健康不适用。"), "实测提示电池缺失")
check(desktopAssessment.notes.contains("助手已连接，但没有找到可写的充电控制键。"), "助手已连接但无键时给出不同提示")

// Intel：功耗与租约限制都适用，系统上限的 80% 下限不适用。
let intel = DeviceProfile(model: "MacBookPro16,1", chip: "Intel(R) Core(TM) i9-9880H",
                          family: .intel, macOSMajor: 13, chargeStrategy: "ch0bch0c",
                          helperAvailable: true, fanCount: 2, hasBattery: true, sensorKeys: ["TB0T"])
let intelAssessment = ruleLibrary.assess(intel)
check(intelAssessment.ruleIDs.contains("intel-no-socpower"), "Intel 命中无 SoC 功耗规则")
check(intelAssessment.ruleIDs.contains("intel-inflow-lease"), "Intel 命中租约规则")
check(!intelAssessment.ruleIDs.contains("system-limit-floor-80"), "80% 下限只约束系统上限后端")
check(!intelAssessment.ruleIDs.contains("apple-silicon-temperature-keys"), "Intel 不命中 Apple Silicon 温度键规则")

// 系统版本与后端都是硬门槛：换一个就不该命中。
var olderMac = laptop
olderMac.macOSMajor = 25
olderMac.chargeStrategy = "bclm"
let olderAssessment = ruleLibrary.assess(olderMac)
check(!olderAssessment.ruleIDs.contains("system-limit-floor-80"), "macOS 25 超出系统上限规则的版本范围")
check(olderAssessment.ruleIDs.contains("bclm-readback"), "BCLM 机器命中回读校验规则")

// 机型前缀大小写不敏感，避免 hw.model 大小写差异导致规则静默失效。
let lowercased = DeviceProfile(model: "macbookair10,1", chip: "Apple M1", family: .appleSilicon,
                               macOSMajor: 12, chargeStrategy: "bclm", helperAvailable: false,
                               fanCount: 0, hasBattery: true, sensorKeys: [])
check(ruleLibrary.assess(lowercased).ruleIDs.contains("fanless-air"), "机型前缀大小写不敏感")

// 多条规则给出同一条限制时只显示一次；同精度按 priority 排序。
let dedupeLibrary = CapabilityRuleLibrary(version: 9, updated: "test", rules: [
    CapabilityRule(id: "a", limitations: ["同一条限制"], recommendations: ["同一条建议"], priority: 1),
    CapabilityRule(id: "b", limitations: ["同一条限制"], recommendations: ["同一条建议"], priority: 2),
])
let deduped = dedupeLibrary.assess(laptop)
check(deduped.limitations == ["同一条限制"], "重复限制只保留一次")
check(deduped.recommendations == ["同一条建议"], "重复建议只保留一次")
check(deduped.ruleIDs == ["b", "a"], "同精度规则按 priority 排序")

// 非法规则库必须被拒绝，而不是带着坏规则运行。
check(CapabilityRuleLibrary(version: 0, updated: "", rules: [
    CapabilityRule(id: "x", recommendations: ["r"])]).validationError != nil, "版本号 0 被拒绝")
check(CapabilityRuleLibrary(version: 1, updated: "", rules: []).validationError != nil, "空规则库被拒绝")
check(CapabilityRuleLibrary(version: 1, updated: "", rules: [
    CapabilityRule(id: "dup", recommendations: ["r"]),
    CapabilityRule(id: "dup", recommendations: ["s"])]).validationError != nil, "重复 id 被拒绝")
check(CapabilityRuleLibrary(version: 1, updated: "", rules: [
    CapabilityRule(id: "empty")]).validationError != nil, "空内容规则被拒绝")

// 版本化与回滚：导入保留旧库，回滚换回旧库并留下反向撤销。
let nextLibrary = CapabilityRuleLibrary(version: 2, updated: "test", rules: [
    CapabilityRule(id: "only", recommendations: ["r"]),
])
let installed = CapabilityRuleArchive.bundled.installing(nextLibrary)
check(installed.current.version == 2 && installed.previous?.version == 1, "导入后保留被替换的版本")
let rolledBack = installed.rollingBack()
check(rolledBack?.current.version == 1 && rolledBack?.previous?.version == 2, "回滚换回旧库并保留撤销能力")
check(CapabilityRuleArchive.bundled.rollingBack() == nil, "没有上一版本时不可回滚")
check(CapabilityRuleArchive.bundled.installing(.bundled) == .bundled, "重复导入同一版本不产生新版本")
let archiveRoundTrip = (try? JSONEncoder().encode(installed)).flatMap {
    try? JSONDecoder().decode(CapabilityRuleArchive.self, from: $0)
}
check(archiveRoundTrip == installed, "规则档案可以完整 JSON 往返")

// 隐私约束：画像只能包含机型代码、芯片名与系统版本这类公开信息。
let profileFields = Set(Mirror(reflecting: laptop).children.compactMap { $0.label })
let allowedFields: Set<String> = ["model", "chip", "family", "macOSMajor", "chargeStrategy",
                                  "helperAvailable", "fanCount", "hasBattery", "sensorKeys"]
check(profileFields == allowedFields, "画像不含序列号等额外字段")
// MARK: - 本地专家建议：阈值、证据、窗口与"数据不足就不给建议"
let adviceNow = Date(timeIntervalSince1970: 1_700_000_000)
func adviceDay(_ offset: Int, high: Double = 0, peak: Double = 30,
               maxPct: Int = 60, plugged: Double = 3600,
               observed: Double = 3600) -> AdviceInput.Day {
    AdviceInput.Day(date: adviceNow.addingTimeInterval(-Double(offset) * 86400),
                    highTemperatureSeconds: high, maxTemperature: peak,
                    maxPercentage: maxPct, pluggedSeconds: plugged,
                    observedSeconds: observed)
}
func adviceSession(_ offset: Int, resistance: Double = 0, capacity: Double = 5000,
                   cycles: Int = 100, preset: String? = nil,
                   start: Int = 100, eligible: Bool = true) -> AdviceInput.Session {
    AdviceInput.Session(date: adviceNow.addingTimeInterval(-Double(offset) * 86400),
                        capacityMAh: capacity, resistanceMilliohm: resistance,
                        healthPercent: 90, cycleCount: cycles, preset: preset,
                        startPercentage: start, eligible: eligible)
}
func adviceInput(_ days: [AdviceInput.Day], _ sessions: [AdviceInput.Session] = [],
                 limit: Int = 100) -> AdviceInput {
    AdviceInput(days: days, sessions: sessions, chargeLimit: limit, now: adviceNow)
}

// 数据不足时不能凭猜测给建议。
let thinAdvice = AdviceEngine.evaluate(adviceInput([adviceDay(1), adviceDay(2)]))
check(thinAdvice.items.isEmpty, "记录不足 7 天时不发布建议")
check(thinAdvice.observedDays == 2, "报告如实统计观测天数")
check(thinAdvice.windowDays == 30, "报告标注统计窗口")
check(thinAdvice.generatedAt == adviceNow, "报告带生成时间")
let unobserved = AdviceEngine.evaluate(adviceInput((0..<10).map { adviceDay($0, high: 9000, observed: 0) }))
check(unobserved.items.isEmpty, "没有观测数据的日子不计入高温时长")

// 高温：10 天各 1.5 小时 = 15 小时，达到阈值；9 天 1.5 小时 = 13.5 小时也达到，
// 因此用 8 小时以下验证不触发。
let hotDays = (0..<10).map { adviceDay($0, high: 5400, peak: 44) }
let hotAdvice = AdviceEngine.evaluate(adviceInput(hotDays))
check(hotAdvice.items.count == 1, "高温达到阈值时只给一条建议")
check(hotAdvice.items.first?.id == "high-temperature", "高温建议的 id 稳定")
check(hotAdvice.items.first?.level == .attention, "高温建议属于需要注意")
check(hotAdvice.items.first?.evidence.count == 3, "高温建议列出三条证据")
check(hotAdvice.items.first?.evidence.allSatisfy { !$0.isEmpty } == true, "证据不能为空")
let warmDays = (0..<10).map { adviceDay($0, high: 2800, peak: 41) }
check(AdviceEngine.evaluate(adviceInput(warmDays)).items.isEmpty, "未到阈值不发布高温建议")

// 充电上限：上限 80% 时 4 天插电冲到 90% 才触发；上限 100% 或未插电都不算。
let overshootDays = (0..<10).map { adviceDay($0, maxPct: $0 < 4 ? 90 : 70) }
let overshootAdvice = AdviceEngine.evaluate(adviceInput(overshootDays, limit: 80))
check(overshootAdvice.items.contains { $0.id == "limit-overshoot" }, "上限未生效时给出建议")
check(AdviceEngine.evaluate(adviceInput(overshootDays, limit: 100)).items.isEmpty,
      "没有上限时不谈超出上限")
let unpluggedDays = (0..<10).map { adviceDay($0, maxPct: 95, plugged: 0) }
check(AdviceEngine.evaluate(adviceInput(unpluggedDays, limit: 80)).items.isEmpty,
      "未插电的放电不当作上限失效")
let briefOvershoot = (0..<10).map { adviceDay($0, maxPct: $0 < 2 ? 90 : 70) }
check(AdviceEngine.evaluate(adviceInput(briefOvershoot, limit: 80)).items.isEmpty,
      "偶发一次超出不发布建议")

// 内阻：三次有效校准从 40 mΩ 升到 50 mΩ（+25%）触发；+10% 不触发。
let risingSessions = [adviceSession(60, resistance: 40, cycles: 100),
                      adviceSession(30, resistance: 45, cycles: 110),
                      adviceSession(5, resistance: 50, cycles: 120)]
let risingAdvice = AdviceEngine.evaluate(adviceInput([], risingSessions))
check(risingAdvice.items.contains { $0.id == "resistance-rise" }, "内阻明显上升时给出建议")
check(risingAdvice.eligibleSessions == 3, "报告统计有效校准次数")
let flatSessions = [adviceSession(60, resistance: 40), adviceSession(30, resistance: 42),
                    adviceSession(5, resistance: 44)]
check(!AdviceEngine.evaluate(adviceInput([], flatSessions)).items.contains { $0.id == "resistance-rise" },
      "内阻小幅波动不发布建议")
let ineligibleSessions = risingSessions.map {
    AdviceInput.Session(date: $0.date, capacityMAh: $0.capacityMAh,
                        resistanceMilliohm: $0.resistanceMilliohm,
                        healthPercent: $0.healthPercent, cycleCount: $0.cycleCount,
                        preset: $0.preset, startPercentage: $0.startPercentage,
                        eligible: false)
}
check(AdviceEngine.evaluate(adviceInput([], ineligibleSessions)).eligibleSessions == 0,
      "低置信度校准不计入内阻比较")

// 深度校准冷却：30 天内做过深度校准就提醒；旧记录按起始电量识别。
let deepAdvice = AdviceEngine.evaluate(adviceInput([], [adviceSession(5, preset: "deep")]))
check(deepAdvice.items.contains { $0.id == "deep-calibration-cooldown" }, "近期深度校准给出冷却建议")
check(deepAdvice.items.first { $0.id == "deep-calibration-cooldown" }?.level == .suggestion,
      "冷却属于建议而非警告")
let legacyDeep = AdviceEngine.evaluate(adviceInput([], [adviceSession(3, start: 10)]))
check(legacyDeep.items.contains { $0.id == "deep-calibration-cooldown" }, "旧记录按起始电量识别深度校准")
let oldDeep = AdviceEngine.evaluate(adviceInput([], [adviceSession(40, preset: "deep")]))
check(!oldDeep.items.contains { $0.id == "deep-calibration-cooldown" }, "超过冷却期不再提醒")
let futureDeep = AdviceEngine.evaluate(adviceInput([], [adviceSession(-2, preset: "deep")]))
check(!futureDeep.items.contains { $0.id == "deep-calibration-cooldown" }, "未来时间的记录不参与判断")

// 排序与窗口：注意类排在建议类之前；30 天外的记录不参与。
let mixedAdvice = AdviceEngine.evaluate(adviceInput(hotDays, [adviceSession(5, preset: "deep")]))
check(mixedAdvice.items.count == 2, "两类建议同时出现")
check(mixedAdvice.items[0].level == .attention, "需要注意的建议排在前面")
let staleDays = (31...40).map { adviceDay($0, high: 9000, peak: 46) }
check(AdviceEngine.evaluate(adviceInput(staleDays)).observedDays == 0, "30 天外的记录不计入窗口")
check(AdviceEngine.evaluate(adviceInput(staleDays)).items.isEmpty, "窗口外的历史不触发建议")

// 充电仲裁（P0-03）：优先级写在 ChargeAuthority 里，执行顺序不能替代它。
check(ChargeAuthority.allCases.map { $0.rawValue } == Array(0...6),
      "策略顺序与文档一致：紧急保护 > 校准 > 手动暂停 > 放电 > 过热保护 > 航海 > 上限")
func arbitrationInput(_ mutate: (inout ChargeArbitrationInput) -> Void) -> ChargeArbitrationInput {
    var input = ChargeArbitrationInput()
    mutate(&input)
    return input
}
func arbitrated(_ input: ChargeArbitrationInput) -> ChargeArbitration? {
    ChargeArbiter.arbitrate(ChargeArbiter.claims(for: input))
}

check(arbitrated(ChargeArbitrationInput(percentage: 50, limit: 80)) == nil,
      "没有策略争夺时不产生仲裁记录")

// 放电高于过热保护：过去靠 if 顺序，结果是过热保护先 return、放电永远不启动。
let hotAndDraining = arbitrationInput {
    $0.percentage = 90; $0.limit = 80; $0.pluggedIn = true
    $0.automaticDischarge = true
    $0.heatProtectMode = true; $0.temperature = 41; $0.maxTemperature = 35
}
let hotVerdict = arbitrated(hotAndDraining)
check(hotVerdict?.winner.strategy == .autoDischarge, "放电优先于过热保护")
check(hotVerdict?.suppressed.map { $0.strategy } == [.heatProtect, .chargeLimit],
      "被覆盖策略按优先级排序写入记录")
check(hotVerdict?.isConflict == true, "两条以上策略同时生效算冲突")
check(hotVerdict?.winner.reason.isEmpty == false, "获胜策略必须带理由")
check(hotVerdict?.suppressedTitles == "过热保护、充电上限", "被覆盖策略合并成一行文本")

// 手动暂停高于放电；紧急保护高于一切。
let pausedAndDraining = arbitrationInput {
    $0.percentage = 90; $0.limit = 80; $0.userPaused = true
    $0.manualDischargeTarget = 60; $0.pluggedIn = true
}
check(arbitrated(pausedAndDraining)?.winner.strategy == .manualPause, "手动暂停优先于放电")
let everythingAtOnce = arbitrationInput {
    $0.percentage = 90; $0.limit = 80; $0.userPaused = true
    $0.manualDischargeTarget = 60; $0.pluggedIn = true
    $0.automaticDischarge = true; $0.heatProtectMode = true; $0.temperature = 45
    $0.calibrationRunning = true; $0.adapterRestoreFailed = true
}
let worstCase = arbitrated(everythingAtOnce)
check(worstCase?.winner.strategy == .emergency, "适配器状态不确定时其它策略全部让位")
check(worstCase?.suppressed.count == 5, "其余策略全部记为被覆盖")

// 校准高于手动暂停，低于紧急保护。
let calibrating = arbitrationInput {
    $0.calibrationRunning = true; $0.userPaused = true; $0.pluggedIn = true
}
check(arbitrated(calibrating)?.winner.strategy == .calibration, "校准优先于手动暂停")

// 航海滞回与上限：低于上限但滞回要求保持时才由航海模式接管。
let sailingHeld = arbitrationInput {
    $0.percentage = 78; $0.limit = 80; $0.pluggedIn = true
    $0.sailingMode = true; $0.sailingLevel = 5; $0.previousChargingAllowed = false
}
check(arbitrated(sailingHeld)?.winner.strategy == .sailing, "航海区间内保持不充电时记为航海策略")
let sailingRecharging = arbitrationInput {
    $0.percentage = 70; $0.limit = 80; $0.pluggedIn = true
    $0.sailingMode = true; $0.sailingLevel = 5; $0.previousChargingAllowed = false
}
check(arbitrated(sailingRecharging) == nil, "跌到航海下沿后允许充电，不算冲突")
let atLimit = arbitrationInput { $0.percentage = 80; $0.limit = 80; $0.pluggedIn = true }
check(arbitrated(atLimit)?.winner.strategy == .chargeLimit, "到达上限记为充电上限策略")

// 同一策略重复申报只算一条，被覆盖列表里不能出现自己。
let claimDuplicates = [ChargeClaim(strategy: .autoDischarge, reason: "a"),
                       ChargeClaim(strategy: .autoDischarge, reason: "b"),
                       ChargeClaim(strategy: .heatProtect, reason: "c")]
let dedupedClaims = ChargeArbiter.arbitrate(claimDuplicates)
check(dedupedClaims?.suppressed.count == 1, "重复申报的策略只保留一条")
check(dedupedClaims.map { ["a", "b"].contains($0.winner.reason) } == true,
      "同策略保留其中一条理由")

// 过热迟滞：温度回落到上限以下但仍在 2°C 缓冲内时，策略仍然成立。
let latchedHeat = arbitrationInput {
    $0.percentage = 50; $0.limit = 80; $0.pluggedIn = true
    $0.heatProtectMode = true; $0.maxTemperature = 35
    $0.temperature = 34; $0.heatPause = true
}
check(arbitrated(latchedHeat)?.winner.strategy == .heatProtect, "过热锁存期间仍由过热保护持有")

// MARK: - 存储自愈：读失败不得变成"数据清零"
let storeDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("infinical-store-" + UUID().uuidString)
try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
let storeFile = storeDir.appendingPathComponent("daily.json")
let storeBackup = StoreIO.backupURL(for: storeFile)
check(storeBackup.lastPathComponent == "daily.bak.json", "备份文件名由主文件推导")
check(StoreIO.quarantineURL(for: storeFile, now: Date(timeIntervalSince1970: 0))
        .lastPathComponent == "daily.corrupt-19700101-000000.json", "隔离文件名带 UTC 时间戳")
check(StoreIO.displayPath(URL(fileURLWithPath: NSHomeDirectory() + "/x/y.json")) == "~/x/y.json",
      "展示路径不泄露账户名")

let goodDays = [DailyStat(day: Date(timeIntervalSince1970: 1_000), temperatureSamples: 1,
                          cycleCount: 12, reportedCapacityMAh: 5000)]
// 首次运行：文件不存在不是故障，也不该触发轮转。
let firstRun = StoreIO.load(DailyStat.self, from: storeFile)
check(firstRun.value.isEmpty && firstRun.status == .clean && !firstRun.safeToRotate,
      "首次运行不报错、不轮转")

check(StoreIO.save(goodDays, to: storeFile, rotate: false), "首写成功")
check(!FileManager.default.fileExists(atPath: storeBackup.path), "首写不产生备份")

// 第二次写：轮转后主文件是新值，备份是旧值。
let dayTwo = [DailyStat(day: Date(timeIntervalSince1970: 2_000), cycleCount: 13)]
check(StoreIO.save(dayTwo, to: storeFile, rotate: true), "轮转写成功")
check(FileManager.default.fileExists(atPath: storeBackup.path), "轮转产生备份")
check(StoreIO.load(DailyStat.self, from: storeFile).value.first?.cycleCount == 13, "主文件是新值")

// 主文件被截断：备份必须接管，坏文件必须留着。
let truncated = Data("[{\\"day\\":\\"2026-01-01T00:00:00Z\\",\\"cyc".utf8)
try truncated.write(to: storeFile)
let recovered = StoreIO.load(DailyStat.self, from: storeFile)
check(recovered.value.map { $0.cycleCount } == [12], "备份接管而不是返回空")
if case .recoveredFromBackup(let path) = recovered.status {
    check(path != nil, "隔离路径必须报告出来")
    check(FileManager.default.fileExists(atPath: path!), "坏文件原样保留")
    let kept = try Data(contentsOf: URL(fileURLWithPath: path!))
    check(kept == truncated, "隔离文件字节不变")
} else {
    check(false, "可恢复时必须报告 recoveredFromBackup")
}
check(recovered.safeToRotate, "恢复出的数据可以继续轮转")
check(StoreIO.load(DailyStat.self, from: storeFile).value.map { $0.cycleCount } == [12],
      "恢复后主文件被重写成可读内容")

// 主文件与备份都坏：从空白开始，但两个坏文件都不能被覆盖。
try Data("not json".utf8).write(to: storeFile)
try Data("also not json".utf8).write(to: storeBackup)
let dead = StoreIO.load(DailyStat.self, from: storeFile)
check(dead.value.isEmpty && !dead.safeToRotate, "双坏时从空白开始且禁止轮转")
if case .startedEmpty(let path) = dead.status {
    check(path != nil && FileManager.default.fileExists(atPath: path!), "双坏时同样保留原件")
} else {
    check(false, "双坏时必须报告 startedEmpty")
}

// 主文件被删除但备份还在：等价于主文件损坏，必须恢复而不是从零开始。
try? FileManager.default.removeItem(at: storeFile)
try? FileManager.default.removeItem(at: storeBackup)
_ = StoreIO.save(goodDays, to: storeFile, rotate: false)
_ = StoreIO.save(dayTwo, to: storeFile, rotate: true)
try? FileManager.default.removeItem(at: storeFile)
let deleted = StoreIO.load(DailyStat.self, from: storeFile)
check(deleted.value.map { $0.cycleCount } == [12], "主文件被删时从备份恢复")
if case .recoveredFromBackup(let path) = deleted.status {
    check(path == nil, "主文件消失时没有可隔离的文件")
} else {
    check(false, "主文件消失但有备份时必须报告 recoveredFromBackup")
}
check(FileManager.default.fileExists(atPath: storeFile.path), "恢复后主文件重新落盘")

// 主文件与备份都不在：这才是真正的首次运行。
try? FileManager.default.removeItem(at: storeFile)
try? FileManager.default.removeItem(at: storeBackup)
let trulyFirst = StoreIO.load(DailyStat.self, from: storeFile)
check(trulyFirst.status == .clean && !trulyFirst.safeToRotate, "没有主文件也没有备份时按首次运行处理")

// 清空必须连备份一起删，否则下次启动会把用户删掉的历史"恢复"回来。
check(StoreIO.save(goodDays, to: storeFile, rotate: false), "重建主文件")
StoreIO.save(goodDays, to: storeFile, rotate: true)
check(FileManager.default.fileExists(atPath: storeBackup.path), "清空前有备份")
StoreIO.discard(file: storeFile)
check(!FileManager.default.fileExists(atPath: storeFile.path)
      && !FileManager.default.fileExists(atPath: storeBackup.path), "清空后主文件与备份都不在")
check(!StoreIO.hasBackup(for: storeFile), "清空后不再报告有备份")
try? FileManager.default.removeItem(at: storeDir)

// MARK: - 低电量：估算、门槛、关闭
// 60 Wh 的包以 30 W 放电 = 2 小时。
check(LowPowerPolicy.minutesLeft(remainingMAh: 5000, voltage: 12, watts: 30) == 120,
      "剩余分钟 = 瓦时 ÷ 瓦 × 60")
check(LowPowerPolicy.minutesLeft(remainingMAh: 5000, voltage: 12, watts: 0.2) == nil,
      "电流过小时拒绝给出估算")
check(LowPowerPolicy.minutesLeft(remainingMAh: 0, voltage: 12, watts: 30) == nil, "没有容量就没有估算")
check(LowPowerPolicy.minutesLeft(remainingMAh: 5000, voltage: 0, watts: 30) == nil, "没有电压就没有估算")

check(LowPowerPolicy.shouldWarn(minutesLeft: 15, lead: 20, percentage: 40), "低于提前量要提醒")
check(!LowPowerPolicy.shouldWarn(minutesLeft: 25, lead: 20, percentage: 40), "高于提前量不提醒")
check(!LowPowerPolicy.shouldWarn(minutesLeft: nil, lead: 20, percentage: 40), "没有估算不报")
check(LowPowerPolicy.shouldWarn(minutesLeft: nil, lead: 20, percentage: 3), "低于 5% 无需估算也报")
check(LowPowerPolicy.shouldWarn(minutesLeft: 600, lead: 20, percentage: 4), "临界电量优先于估算")
check(!LowPowerPolicy.shouldWarn(minutesLeft: 600, lead: 20, percentage: 0),
      "读不到电量（0%）时不按临界处理")
check(!LowPowerPolicy.isCritical(0) && !LowPowerPolicy.isCritical(6), "临界区间是 1…5")

// 放电均值：过旧与充电样本都不能算进"现在还剩多久"。
var watch = DischargeWatch()
let watchStart = Date(timeIntervalSince1970: 10_000)
check(watch.average(at: watchStart) == nil, "没有样本时不给均值")
watch.record(watts: 10, at: watchStart)
watch.record(watts: 30, at: watchStart.addingTimeInterval(1))
check(watch.average(at: watchStart.addingTimeInterval(1)) == 20, "两样本取均值")
watch.record(watts: -5, at: watchStart.addingTimeInterval(2))
check(watch.sampleCount == 2, "充电（负功率）样本不参与")
watch.record(watts: Double.nan, at: watchStart.addingTimeInterval(2))
check(watch.sampleCount == 2, "非有限值样本不参与")
// 窗口外的旧样本必须滑出。
watch.record(watts: 40, at: watchStart.addingTimeInterval(DischargeWatch.window + 60))
check(watch.sampleCount == 1 && watch.average(at: watchStart.addingTimeInterval(DischargeWatch.window + 60)) == 40,
      "窗口外的样本滑出")
// 全部过期后不再给出均值。
check(watch.average(at: watchStart.addingTimeInterval(DischargeWatch.window + 60 + DischargeWatch.staleAfter + 1)) == nil,
      "样本过期后不给均值")
watch.reset()
check(watch.sampleCount == 0, "reset 清空窗口")

// 证据行：有估算时说清功率与窗口，没有估算时不编造数字。
let withEstimate = LowPowerPolicy.evidence(percentage: 12, leadMinutes: 20,
                                          averageWatts: 30, minutesLeft: 120, windowSeconds: 180)
check(withEstimate.contains("12%") && withEstimate.contains("30.0 W")
      && withEstimate.contains("180 s") && withEstimate.contains("120 min"),
      "证据行包含电量、功率、窗口与剩余时间")
let withoutEstimate = LowPowerPolicy.evidence(percentage: 3, leadMinutes: 20,
                                             averageWatts: nil, minutesLeft: nil, windowSeconds: 180)
check(withoutEstimate.contains("无法估算") && !withoutEstimate.contains("→ 剩余"),
      "没有估算时不下结论")
check(!withoutEstimate.contains("0.0 W"), "没有估算时不写 0 W")

// 恢复门槛必须高于触发门槛，否则规则会在阈值附近反复触发。
check(LowPowerPolicy.recoveryMinutes(lead: 20) == 25, "20 分钟提前量的恢复门槛是 25 分钟")
check(LowPowerPolicy.recoveryMinutes(lead: 60) > LowPowerPolicy.recoveryMinutes(lead: 20),
      "提前量越大恢复门槛越高")
check(LowPowerPolicy.recoveryMinutes(lead: 5) >= 6, "极小提前量也留出余量")
for lead in LowPowerPolicy.leadOptions {
    check(LowPowerPolicy.recoveryMinutes(lead: lead) > lead, "恢复门槛永远高于触发门槛")
}

// 端到端：把策略接进门控跑一遍"放电 → 告警 → 回升 → 再降"。
// `AnomalyGate` 在采样间隔 > 10 s 时会清空证据，所以这里每 5 秒一步。
var lowGate = AnomalyGate()
let lowRule = AnomalyRule(id: "lowPower", title: "电量即将用尽", duration: 30, cooldown: 600)
let t0 = Date(timeIntervalSince1970: 500_000)
func lowStep(_ seconds: Double, minutes: Int?, percentage: Int, plugged: Bool = false) -> Bool {
    let now = t0.addingTimeInterval(seconds)
    lowGate.beginSample(at: now)
    let warn = !plugged && LowPowerPolicy.shouldWarn(minutesLeft: minutes, lead: 20, percentage: percentage)
    let recover = LowPowerPolicy.shouldRecover(percentage: percentage, minutesLeft: minutes,
                                               lead: 20, pluggedIn: plugged)
    return lowGate.evaluate(lowRule, trigger: warn, recover: recover, now: now)
}
check(!lowStep(0, minutes: 90, percentage: 60), "电量充足时不提醒")
check(!lowStep(5, minutes: 18, percentage: 30), "刚进入提前量时先累积证据")
check(!lowStep(15, minutes: 18, percentage: 30), "持续不足 30 秒仍不提醒")
check(!lowStep(25, minutes: 18, percentage: 30), "第 25 秒仍在累积")
check(lowStep(35, minutes: 18, percentage: 30), "持续 30 秒后提醒")
check(!lowStep(40, minutes: 17, percentage: 29), "冷却期内不重复提醒")
check(!lowStep(45, minutes: 40, percentage: 32), "回升到恢复门槛以上时解除")
check(!lowStep(55, minutes: 18, percentage: 30), "再次进入提前量后重新累积证据")
check(!lowStep(65, minutes: 18, percentage: 30), "冷却未结束时仍不提醒")
check(!lowStep(80, minutes: 18, percentage: 30), "冷却期内不重复提醒（600 秒）")
// 冷却结束后重新累积 30 秒证据再提醒（步长必须 ≤ 10 s，否则门控会重置证据）。
check(!lowStep(640, minutes: 18, percentage: 30), "冷却结束后重新计时")
for step in stride(from: 645.0, through: 665.0, by: 5) {
    check(!lowStep(step, minutes: 18, percentage: 30), "证据仍在累积")
}
check(lowStep(670, minutes: 18, percentage: 30), "冷却结束后可再次提醒")
check(!lowStep(675, minutes: 18, percentage: 30, plugged: true), "插电即恢复")

// 临界电量：没有估算也要提醒，插电同样恢复。单独一个门控，避免冷却期串扰。
var criticalGate = AnomalyGate()
func criticalStep(_ seconds: Double, percentage: Int, plugged: Bool = false) -> Bool {
    let now = t0.addingTimeInterval(seconds)
    criticalGate.beginSample(at: now)
    let warn = !plugged && LowPowerPolicy.shouldWarn(minutesLeft: nil, lead: 20, percentage: percentage)
    let recover = LowPowerPolicy.shouldRecover(percentage: percentage, minutesLeft: nil,
                                               lead: 20, pluggedIn: plugged)
    return criticalGate.evaluate(lowRule, trigger: warn, recover: recover, now: now)
}
check(!criticalStep(0, percentage: 8), "8% 且无估算时不提醒")
check(!criticalStep(5, percentage: 4), "临界电量先累积 30 秒证据")
for step in stride(from: 10.0, through: 30.0, by: 5) {
    check(!criticalStep(step, percentage: 4), "临界证据仍在累积")
}
check(criticalStep(35, percentage: 4), "4% 无估算也提醒")
_ = criticalStep(40, percentage: 4, plugged: true)
check(!criticalStep(45, percentage: 4, plugged: true), "插电后临界也不提醒")

// 恢复条件：插电即恢复；电量在临界区上方的估算回升才恢复；无估算视为恢复。
check(LowPowerPolicy.shouldRecover(percentage: 30, minutesLeft: 5, lead: 20, pluggedIn: true),
      "插电即恢复")
check(!LowPowerPolicy.shouldRecover(percentage: 30, minutesLeft: 15, lead: 20, pluggedIn: false),
      "仍低于门槛时不恢复")
check(LowPowerPolicy.shouldRecover(percentage: 30, minutesLeft: 26, lead: 20, pluggedIn: false),
      "超过恢复门槛后恢复")
check(!LowPowerPolicy.shouldRecover(percentage: 4, minutesLeft: 600, lead: 20, pluggedIn: false),
      "临界电量高于门槛下也不该清除提醒")
check(LowPowerPolicy.shouldRecover(percentage: 30, minutesLeft: nil, lead: 20, pluggedIn: false),
      "没有估算（几乎无功耗）时不再算低电量")

print("PASS pure policy/math/checkpoint/helper-validation/quality/trend/anomaly/profile/advice/arbitration/store/low-power tests (no hardware)")
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
    # Sparkle must be embedded where the rpath expects it, and its XPC services
    # must survive signing — codesign --deep on the bundle breaks them.
    sparkle = app / "Contents/Frameworks/Sparkle.framework"
    assert sparkle.is_dir(), "Sparkle.framework not embedded in the app"
    for xpc in ("Installer.xpc", "Downloader.xpc"):
        assert (sparkle / "Versions/B/XPCServices" / xpc).is_dir(), "missing XPC service: " + xpc
    rpaths = subprocess.check_output(
        ["otool", "-l", str(app / "Contents/MacOS/InfiniCal")], text=True)
    assert "@executable_path/../Frameworks" in rpaths, "missing framework rpath"
    linked = subprocess.check_output(
        ["otool", "-L", str(app / "Contents/MacOS/InfiniCal")], text=True)
    assert "@rpath/Sparkle.framework" in linked, "app does not link Sparkle"
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


def screenshots():
    """Compare Tools/screenshots/current against the committed baseline."""
    current = ROOT / "Tools/screenshots/current"
    if not current.is_dir():
        raise SystemExit("no current screenshots — run bash Tools/capture_panels.sh first")
    result = subprocess.run([sys.executable, str(ROOT / "Tools/compare_screenshots.py")],
                            capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit("screenshot gate failed")
    print(result.stderr.strip(), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["source", "test", "artifact", "screenshots", "all"],
                        default="all", nargs="?")
    parser.add_argument("--dmg")
    args = parser.parse_args()
    if args.stage in ("source", "all"): source_gate()
    if args.stage in ("test", "all"): tests()
    if args.stage in ("artifact", "all"): artifact_gate(args.dmg)
    # Screenshots are deliberately outside `all`: they need a built app, a
    # visible window and a capture run, so they are a separate, explicit step.
    if args.stage == "screenshots": screenshots()
