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
    smc_source = (ROOT / "Sources/Core/SMC.swift").read_text()
    smc_info = smc_source[smc_source.index("struct SMCKeyInfo {"):smc_source.index("enum SMCError:")]
    smc_loads = smc_source[smc_source.index("    fileprivate static func loadU8"):smc_source.index("    // MARK: - Typed helpers")]
    smc_decode = smc_source[smc_source.index("    static func decode("):smc_source.index("    func writeUInt8(")]
    swift = "import Foundation\n" + policy + checkpoint + quality + conditions + export + record
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
    app_state = (ROOT / "Sources/Core/AppState.swift").read_text()
    fan_source = (ROOT / "Sources/Core/FanController.swift").read_text()
    update_methods = app_state[app_state.index("    func prepareForUpdate()"):app_state.index("    private func tick()", app_state.index("    func prepareForUpdate()"))]
    fan_cancel = fan_source[fan_source.index("    func completeUpdateCancellation()"):fan_source.index("    // MARK: - Persistence")]
    fan_properties = fan_source[fan_source.index("    @Published var modes:"):fan_source.index("    @Published var curveSensorKey:")].replace("@Published ", "").replace("UserDefaults.standard", "defaults")
    swift += '''
// 只抽取生产入口与成功取消方法；所有外部依赖均为内存桩。
func t(_ text: String) -> String { text }
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["source", "test", "artifact", "all"], default="all", nargs="?")
    parser.add_argument("--dmg")
    args = parser.parse_args()
    if args.stage in ("source", "all"): source_gate()
    if args.stage in ("test", "all"): tests()
    if args.stage in ("artifact", "all"): artifact_gate(args.dmg)
