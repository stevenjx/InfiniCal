//
//  FanController.swift
//  Real fan control and thermal telemetry.
//
//  Everything here is read from, or written to, keys this Mac actually exposes.
//  Nothing is inferred:
//
//    FNum      ui8   number of fans (0 on fanless models)
//    F{n}Ac    flt   current RPM
//    F{n}Mn    flt   minimum RPM
//    F{n}Mx    flt   maximum RPM
//    F{n}Tg    flt   target RPM            (writable)
//    F{n}Md    ui8   0 = system automatic, 1 = forced  (writable)
//    F{n}ID    ch8*  fan label, Intel models only
//
//  Apple Silicon has no `FS!` bitmask key — the per-fan mode key `F{n}Md` is the
//  switch. Intel models keep `FS!`, which is handled as a fallback so the same
//  code works on both.
//

import Foundation

// MARK: - Models

struct FanInfo: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    var name: String
    var currentRPM: Int
    var minRPM: Int
    var maxRPM: Int
    var targetRPM: Int
    /// true when the SMC says the fan is being driven by us rather than the system.
    var isManual: Bool
    var canControl: Bool
    /// Reported only when the SMC exposes F{n}ID (Intel). Apple Silicon does not.
    var hasOwnLabel: Bool
}

enum FanMode: String, Codable {
    case auto
    case fixed
    case full

    var title: String {
        switch self {
        case .auto: return t("自动")
        case .fixed: return t("自定义")
        case .full: return t("全速")
        }
    }
}

struct FanPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Fan index → mode.
    var modes: [Int: FanMode]
    /// Fan index → fixed RPM.
    var rpms: [Int: Int]
    var curveEnabled: Bool = false
}

struct ThermalReading: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    /// Where the number came from, shown in the UI so nothing looks invented.
    let source: String
    let celsius: Double
}

// MARK: - Controller

final class FanController: ObservableObject {

    static let shared = FanController()

    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var sensors: [ThermalReading] = []
    @Published private(set) var lastError: String?

    /// Per-fan mode chosen in the UI.
    @Published var modes: [Int: FanMode] = [:] {
        didSet { persistModes() }
    }
    /// Per-fan fixed RPM chosen in the UI.
    @Published var fixedRPM: [Int: Int] = [:] {
        didSet { persistModes() }
    }

    /// Temperature-driven mode.
    @Published var curveEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(curveEnabled, forKey: Keys.curveEnabled)
            lastCurveTemperature = nil
            DispatchQueue.main.async { [weak self] in self?.applyCurveIfNeeded(force: true) }
        }
    }
    @Published var curveSensorKey: String = "cpu-die" {
        didSet { UserDefaults.standard.set(curveSensorKey, forKey: Keys.curveSensor) }
    }
    @Published var curveStartTemperature: Double = 50 {
        didSet { UserDefaults.standard.set(curveStartTemperature, forKey: Keys.curveStart) }
    }
    @Published var curvePeakTemperature: Double = 85 {
        didSet { UserDefaults.standard.set(curvePeakTemperature, forKey: Keys.curvePeak) }
    }
    /// Middle anchor: the curve is piecewise linear, so a laptop can stay quiet
    /// through the idle range and still ramp hard near the top.
    @Published var curveMidTemperature: Double = 68 {
        didSet { UserDefaults.standard.set(curveMidTemperature, forKey: Keys.curveMid) }
    }
    /// Fan speed at the middle anchor, as a percentage of the usable range.
    @Published var curveMidPercent: Double = 45 {
        didSet { UserDefaults.standard.set(curveMidPercent, forKey: Keys.curveMidPercent) }
    }

    @Published private(set) var presets: [FanPreset] = []
    @Published private(set) var activePresetName: String?

    var hasFans: Bool { !fans.isEmpty }
    var isAnyManual: Bool { fans.contains { $0.isManual } }

    private enum Keys {
        static let modes = "fanModes"
        static let rpms = "fanFixedRPM"
        static let presets = "fanPresets"
        static let curveEnabled = "fanCurveEnabled"
        static let curveSensor = "fanCurveSensor"
        static let curveStart = "fanCurveStart"
        static let curvePeak = "fanCurvePeak"
        static let curveMid = "fanCurveMidTemperature"
        static let curveMidPercent = "fanCurveMidPercent"
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var pageUsers = 0
    /// A calibration owns the fans for the length of its session; it keeps the
    /// sampler alive even with no page open, and drives the curve itself.
    private var sessionCooling = false
    private var modesBeforeSession: [Int: FanMode] = [:]
    private var lastCurveWrite: [Int: Int] = [:]
    private var lastCurveTemperature: Double?
    /// Intel die temperature, filled asynchronously by the privileged sampler.
    private var powermetricsCPUTemp: Double?
    private var usesHIDForCPU = true
    private var lastAppliedFixed: [Int: Int] = [:]

    private init() {
        loadPersistedSettings()
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    func beginMonitoring() {
        pageUsers += 1
        // Called from onAppear, which runs inside a view update — read the SMC on
        // the next tick instead of publishing from there.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refresh()
            self.syncModesFromHardware()
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endMonitoring() {
        pageUsers = max(0, pageUsers - 1)
        guard pageUsers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    var updateSuspended = false

    private func tick() {
        guard !updateSuspended else { return }
        refresh()
        applyCurveIfNeeded()
        refreshPowermetricsCPUTemperature()
    }

    // MARK: - Session cooling

    /// A calibration run heats the SoC on purpose for tens of minutes. While it
    /// runs the fans follow the same curve as 风扇控制 — even when the user has
    /// never enabled it — because leaving the machine on the system's own ramp
    /// let it sit at 90 °C+ with the fans barely moving.
    ///
    /// The user's own modes are captured first and put back by
    /// `endSessionCooling`, so a session never changes a fan setting for good.
    func beginSessionCooling() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.sessionCooling else { return }
            self.sessionCooling = true
            self.modesBeforeSession = self.modes
            self.lastCurveTemperature = nil
            self.lastCurveWrite.removeAll()
            self.beginMonitoring()
            self.applyCurveIfNeeded(force: true)
        }
    }

    func endSessionCooling() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionCooling else { return }
            self.sessionCooling = false
            self.lastCurveTemperature = nil
            self.lastCurveWrite.removeAll()
            let saved = self.modesBeforeSession
            self.modesBeforeSession.removeAll()
            // With the user's curve enabled it is already in charge and keeps
            // driving the fans; only a session that took them over has to hand
            // them back.
            if !self.curveEnabled {
                for fan in self.fans {
                    switch saved[fan.index] ?? .auto {
                    case .auto: self.applyAuto(index: fan.index)
                    case .full: self.applyFixed(index: fan.index, rpm: fan.maxRPM)
                    case .fixed: self.applyFixed(index: fan.index, rpm: self.fixedRPM[fan.index] ?? fan.currentRPM)
                    }
                }
            }
            self.endMonitoring()
        }
    }

    // MARK: - Reading

    func refresh() {
        let updated = readFansNow()
        if updated != fans { fans = updated }

        let thermal = readSensors()
        if thermal != sensors { sensors = thermal }

        // Seed UI state from the hardware on first sight so the panel never shows
        // a made-up default.
        for fan in updated where modes[fan.index] == nil {
            modes[fan.index] = fan.isManual ? .fixed : .auto
            fixedRPM[fan.index] = fan.isManual ? fan.targetRPM : fan.currentRPM
        }
    }

    /// Single source of truth for fan readings: one fan-count rule, one rounding
    /// rule, one place that touches the SMC. Everything else reads `fans`.
    private func readFansNow() -> [FanInfo] {
        let count = fanCount()
        var result: [FanInfo] = []
        for index in 0..<count {
            guard let current = readFloat("F\(index)Ac") else { continue }
            let minRPM = Int((readFloat("F\(index)Mn") ?? 0).rounded())
            let maxRPM = Int((readFloat("F\(index)Mx") ?? 0).rounded())
            let target = Int((readFloat("F\(index)Tg") ?? current).rounded())
            result.append(FanInfo(index: index,
                                  name: fanLabel(index: index, total: count),
                                  currentRPM: Int(current.rounded()),
                                  minRPM: minRPM,
                                  maxRPM: maxRPM,
                                  targetRPM: target,
                                  isManual: readMode(index: index),
                                  canControl: maxRPM > minRPM
                                      && (writeKeyExists("F\(index)Md") || fsFlagsWritable),
                                  hasOwnLabel: readString("F\(index)ID") != nil))
        }
        return result
    }

    /// The SMC forgets forced mode across reboots, so trust the hardware when the
    /// page opens instead of showing a stale "自定义" that is not in effect.
    private func syncModesFromHardware() {
        guard !curveEnabled else { return }
        var updatedModes = modes
        for fan in fans {
            let ui = updatedModes[fan.index] ?? .auto
            if !fan.isManual, ui != .auto { updatedModes[fan.index] = .auto }
        }
        if updatedModes != modes { modes = updatedModes }
    }

    /// FNum is authoritative; counting F{n}Ac is the fallback for models that do
    /// not expose it.
    private func fanCount() -> Int {
        if let info = SMC.shared.keyInfo("FNum"), info.size == 1,
           let value = try? SMC.shared.readDouble("FNum"), value >= 0, value <= 8 {
            return Int(value)
        }
        var count = 0
        for index in 0..<8 where SMC.shared.keyInfo("F\(index)Ac") != nil { count = index + 1 }
        return count
    }

    private func fanLabel(index: Int, total: Int) -> String {
        if let label = readString("F\(index)ID"), !label.isEmpty { return label }
        if total == 1 { return t("风扇") }
        if total == 2 { return index == 0 ? t("风扇 1（左）") : t("风扇 2（右）") }
        return tf("风扇 {p}", "\(index + 1)")
    }

    private func readMode(index: Int) -> Bool {
        if let value = try? SMC.shared.readDouble("F\(index)Md") { return value >= 1 }
        if let flags = try? SMC.shared.readDouble("FS! ") {
            return Int(flags) & (1 << (index * 2)) != 0
        }
        return false
    }

    private func writeKeyExists(_ key: String) -> Bool {
        SMC.shared.keyInfo(key)?.isWritable ?? false
    }

    /// Intel models carry no `F{n}Md`; the mode bits live inside `FS!` instead.
    /// Without this the fan was reported as uncontrollable there, so every write
    /// was refused before `writeMode` ever reached its `FS!` branch.
    private var fsFlagsWritable: Bool {
        SMC.shared.keyInfo("FS! ")?.isWritable ?? false
    }

    private func readFloat(_ key: String) -> Double? {
        guard let value = try? SMC.shared.readDouble(key), value.isFinite else { return nil }
        return value
    }

    private func readString(_ key: String) -> String? {
        guard let (_, bytes) = try? SMC.shared.readBytes(key) else { return nil }
        let trimmed = bytes.prefix { $0 != 0 }
        guard !trimmed.isEmpty else { return nil }
        return String(bytes: trimmed, encoding: .ascii)
    }

    // MARK: - Thermal sensors

    private func readSensors() -> [ThermalReading] {
        var result: [ThermalReading] = []

        let cpu = cpuTemperature()
        if cpu.value > 0 {
            result.append(ThermalReading(key: "cpu-die", name: "CPU",
                                         source: cpu.source, celsius: cpu.value))
        }

        // The pack's own gauge, the same reading the dashboard shows. SMC TB0T
        // reads a different point on Intel — 102 °C against the gauge's 30 °C on
        // a captured MacBookPro15,1 — so it is not used here.
        let battery = BatteryReader.read().temperature
        if battery > 5, battery < 110 {
            result.append(ThermalReading(key: "battery", name: t("电池"),
                                         source: t("电池仪表"), celsius: battery))
        }

        if let nand = HIDThermal.average(where: { $0.lowercased().contains("nand") }) {
            result.append(ThermalReading(key: "ssd", name: t("固态硬盘"), source: "HID · NAND", celsius: nand))
        }

        if let gpu = smcGPUReading() {
            result.append(gpu)
        }
        return result
    }

    /// CPU die temperature, and where it came from.
    ///
    /// Apple Silicon exposes `PMU tdie*` through HID and four core clusters
    /// through the SMC. Intel has neither: it reports `TC0D` (the die, the same
    /// quantity `powermetrics` prints as "CPU die temperature") plus proximity
    /// sensors. Without that branch this returned 0 on Intel machines, so the
    /// curve sensor had no value and fan control never engaged at all.
    private func cpuTemperature() -> (value: Double, source: String) {
        if let hid = HIDThermal.average(where: { $0.lowercased().contains("tdie") }) {
            usesHIDForCPU = true
            return (hid, t("HID · PMU tdie 平均"))
        }
        usesHIDForCPU = false
        let socKeys = ["Tp01", "Tp05", "Tp09", "Tp0D"]
        let socValues = socKeys.compactMap { readFloat($0) }.filter { $0 > 5 && $0 < 110 }
        if !socValues.isEmpty {
            return (socValues.reduce(0, +) / Double(socValues.count),
                    t("SMC Tp01/Tp05/Tp09/Tp0D 平均"))
        }
        // Intel. Its SMC CPU keys are not trustworthy: TC0P reported 96 °C on a
        // MacBookPro15,1 while powermetrics measured 43 °C for the same die. The
        // privileged `smc` sampler is the source that agrees with the system, and
        // tick() keeps it warm.
        if let die = powermetricsCPUTemp {
            return (die, t("powermetrics · smc 采样器"))
        }
        return (0, "")
    }

    /// Keeps the Intel die temperature warm. No-op on Apple Silicon, where the
    /// HID reading is already available at 1 Hz.
    private func refreshPowermetricsCPUTemperature() {
        guard !usesHIDForCPU else { return }
        HelperClient.shared.cpuDieTemperature { [weak self] value in
            guard let value else { return }
            self?.powermetricsCPUTemp = value
        }
    }

    /// GPU cluster temperature, only when the SMC actually reports one.
    private func smcGPUReading() -> ThermalReading? {
        let keys = ["Tg0B", "Tg0C", "Tg0H", "TG0V"]
        let values = keys.compactMap { readFloat($0) }.filter { $0 > 5 && $0 < 110 }
        guard !values.isEmpty else { return nil }
        return ThermalReading(key: "gpu", name: "GPU",
                              source: "SMC " + keys.filter { readFloat($0) != nil }.joined(separator: "/"),
                              celsius: values.reduce(0, +) / Double(values.count))
    }

    /// All HID temperature services, averaged per product name. Used for the
    /// expandable "all sensors" list so nothing is hidden or invented.
    func allHIDSensors() -> [ThermalReading] {
        var buckets: [String: [Double]] = [:]
        for reading in HIDThermal.readings() {
            buckets[reading.name, default: []].append(reading.celsius)
        }
        return buckets.keys.sorted().compactMap { name in
            guard let values = buckets[name], !values.isEmpty else { return nil }
            return ThermalReading(key: name, name: name,
                                  source: values.count > 1 ? tf("HID · {p} 个服务平均", "\(values.count)") : "HID",
                                  celsius: values.reduce(0, +) / Double(values.count))
        }
    }

    // MARK: - Control

    func setMode(_ mode: FanMode, for index: Int) {
        guard !updateSuspended else { return }
        // UI actions arrive while SwiftUI is still inside a view update; mutating
        // @Published there triggers "Publishing changes from within view updates".
        // Hop to the next runloop tick so every state change is published outside
        // the update transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.modes[index] = mode
            switch mode {
            case .auto:
                self.applyAuto(index: index)
            case .full:
                self.applyFixed(index: index, rpm: self.fan(index)?.maxRPM ?? 0)
            case .fixed:
                self.lastAppliedFixed[index] = self.fixedRPM[index] ?? self.fan(index)?.currentRPM ?? 0
                self.applyFixed(index: index, rpm: self.fixedRPM[index] ?? self.fan(index)?.currentRPM ?? 0)
            }
        }
    }

    /// UI entry points for the curve settings: same reason as `setMode`, the
    /// write is deferred out of the view update transaction.
    func setCurveEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.curveEnabled = enabled }
    }

    func setCurveSensor(_ key: String) {
        DispatchQueue.main.async { [weak self] in self?.curveSensorKey = key }
    }

    func setFixedRPM(_ rpm: Int, for index: Int) {
        guard let fan = fan(index) else { return }
        let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
        fixedRPM[index] = clamped
        guard modes[index] == .fixed else { return }
        // Dragging the slider fires dozens of values per second; only push to the
        // SMC when the target actually moved enough to matter.
        if let last = lastAppliedFixed[index], abs(last - clamped) < 15 { return }
        lastAppliedFixed[index] = clamped
        DispatchQueue.main.async { [weak self] in
            self?.applyFixed(index: index, rpm: clamped)
        }
    }

    func setAllAuto() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.curveEnabled = false
            for fan in self.fans {
                self.modes[fan.index] = .auto
                self.applyAuto(index: fan.index)
            }
            self.activePresetName = t("自动")
        }
    }

    func setAllFull() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.curveEnabled = false
            for fan in self.fans {
                self.modes[fan.index] = .full
                self.applyFixed(index: fan.index, rpm: fan.maxRPM)
            }
            self.activePresetName = t("全速")
        }
    }

    private func applyAuto(index: Int) {
        var phase = ControlPhase.accepted
        var detail: String?
        do {
            try writeMode(index: index, manual: false)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            phase = .failed
            detail = error.localizedDescription
        }
        refresh()
        // A write that returned without throwing is only "accepted". Reading the
        // fan back is what turns it into "verified", and only when the SMC
        // actually reports the fan out of manual mode.
        if phase != .failed, let after = fan(index) {
            phase = after.isManual ? .accepted : .verified
        }
        recordFanControl(index: index, phase: phase, target: "auto", detail: detail)
    }

    private func applyFixed(index: Int, rpm: Int) {
        guard !updateSuspended else { return }
        guard let fan = fan(index), fan.canControl else {
            lastError = t("此机型未暴露可写的风扇控制键")
            recordFanControl(index: index, phase: .failed, target: "\(rpm) rpm",
                             detail: lastError)
            return
        }
        let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
        var phase = ControlPhase.accepted
        var detail: String?
        do {
            // Mode first, then target: the SMC only honours F{n}Tg once the fan is
            // out of automatic mode.
            try writeMode(index: index, manual: true)
            try writeFloat("F\(index)Tg", Double(clamped))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            phase = .failed
            detail = error.localizedDescription
        }
        refresh()
        if phase != .failed, let after = self.fan(index) {
            // Both halves have to agree: still ours, and the target RPM landed.
            let matchesTarget = abs(after.targetRPM - clamped) <= max(20, clamped / 20)
            phase = (after.isManual && matchesTarget) ? .verified : .accepted
        }
        recordFanControl(index: index, phase: phase, target: "\(clamped) rpm", detail: detail)
    }

    /// One entry per fan action, so the journal answers "asked for, accepted,
    /// confirmed" without three rows per slider tick.
    private func recordFanControl(index: Int, phase: ControlPhase, target: String, detail: String?) {
        let after = fan(index)
        let observed = after.map { "Md=\($0.isManual ? "manual" : "auto") Tg=\($0.targetRPM)" }
        ControlJournal.shared.record(ControlEvidence(operation: "fan.mode", backend: "smc",
                                                     phase: phase, target: "F\(index) \(target)",
                                                     observed: observed, detail: detail))
    }

    private func writeMode(index: Int, manual: Bool) throws {
        if manual && updateSuspended { throw HelperError.smc(t("自动控制已暂停；请重试安全退出，或明确恢复控制。")) }
        if SMC.shared.keyInfo("F\(index)Md")?.isWritable == true {
            try HelperClient.shared.smcWriteBytes("F\(index)Md", [manual ? 1 : 0])
            return
        }
        // Intel fallback: two bits per fan inside FS!.
        if let info = SMC.shared.keyInfo("FS! "), info.size == 2 {
            let current = (try? SMC.shared.readDouble("FS! ")) ?? 0
            var flags = Int(current)
            let shift = index * 2
            flags &= ~(0x3 << shift)
            if manual { flags |= (0x1 << shift) }
            let bytes = [UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)]
            try HelperClient.shared.smcWriteBytes("FS! ", bytes)
            return
        }
        throw HelperError.smc(t("此机型未暴露风扇模式键"))
    }

    private func writeFloat(_ key: String, _ value: Double) throws {
        guard let info = SMC.shared.keyInfo(key) else { throw HelperError.smc(tf("SMC 键 {p} 不存在", key)) }
        guard info.isWritable else { throw HelperError.smc(tf("SMC 键 {p} 为只读", key)) }
        let bytes = try encode(value, for: info)
        try HelperClient.shared.smcWriteBytes(key, bytes)
    }

    /// Encodes a value using the key's declared type, verifying the byte order by
    /// decoding the result back through the same decoder the reader uses.
    private func encode(_ value: Double, for info: SMCKeyInfo) throws -> [UInt8] {
        switch info.type {
        case "flt ":
            let pattern = Float(value).bitPattern
            let little = withUnsafeBytes(of: pattern.littleEndian) { Array($0) }
            let big = withUnsafeBytes(of: pattern.bigEndian) { Array($0) }
            if let decoded = try? SMC.decode(info: info, bytes: little), abs(decoded - value) < 1 {
                return little
            }
            if let decoded = try? SMC.decode(info: info, bytes: big), abs(decoded - value) < 1 {
                return big
            }
            return little
        case "ui8 ":
            return [UInt8(clamping: Int(value))]
        case "ui16":
            let raw = UInt16(clamping: Int(value))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "fpe2":
            let raw = UInt16(clamping: Int((value * 4).rounded()))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            throw HelperError.smc(tf("不支持写入类型 {p}", info.type))
        }
    }

    // MARK: - Curve

    private func applyCurveIfNeeded(force: Bool = false) {
        guard !updateSuspended else { return }
        guard curveEnabled || sessionCooling else { return }
        guard let temperature = curveTemperature() else { return }
        // 1 °C deadband: without it a sensor sitting on a threshold rewrites the
        // same target every second and the fan audibly hunts.
        if !force, let last = lastCurveTemperature, abs(temperature - last) < 1.0 { return }
        lastCurveTemperature = temperature

        for fan in fans where fan.canControl {
            var target = curveRPM(temperature: temperature, fan: fan)
            if !force, let previous = lastCurveWrite[fan.index] {
                // Ramp limit: 150 RPM per tick (1 s), so a step in temperature
                // becomes a sweep instead of an audible jump.
                target = min(max(target, previous - 150), previous + 150)
            }
            if !force, let last = lastCurveWrite[fan.index], abs(last - target) < 40 { continue }
            lastCurveWrite[fan.index] = target
            do {
                try writeFloat("F\(fan.index)Tg", Double(target))
                try writeMode(index: fan.index, manual: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
        if force { refresh() }
    }

    private func curveTemperature() -> Double? {
        switch curveSensorKey {
        case "battery":
            return sensors.first { $0.key == "battery" }?.celsius
        case "ssd":
            return sensors.first { $0.key == "ssd" }?.celsius
        case "gpu":
            return sensors.first { $0.key == "gpu" }?.celsius
        default:
            return sensors.first { $0.key == "cpu-die" }?.celsius
        }
    }

    /// Piecewise linear through three anchors: (start → min), (mid → mid %),
    /// (peak → max). Temperatures outside the anchors clamp to the ends.
    func curveRPM(temperature: Double, fan: FanInfo) -> Int {
        let start = min(curveStartTemperature, curvePeakTemperature - 2)
        let peak = max(curvePeakTemperature, start + 2)
        let mid = min(max(curveMidTemperature, start + 1), peak - 1)
        let span = Double(fan.maxRPM - fan.minRPM)
        let midRPM = Double(fan.minRPM) + span * min(100, max(0, curveMidPercent)) / 100

        let rpm: Double
        if temperature <= start {
            rpm = Double(fan.minRPM)
        } else if temperature < mid {
            let ratio = (temperature - start) / (mid - start)
            rpm = Double(fan.minRPM) + (midRPM - Double(fan.minRPM)) * ratio
        } else if temperature < peak {
            let ratio = (temperature - mid) / (peak - mid)
            rpm = midRPM + (Double(fan.maxRPM) - midRPM) * ratio
        } else {
            rpm = Double(fan.maxRPM)
        }
        return Int(min(max(rpm, Double(fan.minRPM)), Double(fan.maxRPM)).rounded())
    }

    /// Target RPM for the current temperature, for the UI readout.
    func projectedRPM(temperature: Double) -> Int? {
        guard let fan = fans.first else { return nil }
        return curveRPM(temperature: temperature, fan: fan)
    }

    // MARK: - Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = FanPreset(name: trimmed, modes: modes, rpms: fixedRPM, curveEnabled: curveEnabled)
        presets.removeAll { $0.name == trimmed }
        presets.append(preset)
        persistPresets()
        activePresetName = trimmed
    }

    func apply(_ preset: FanPreset) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.curveEnabled = preset.curveEnabled
            self.modes = preset.modes
            self.fixedRPM = preset.rpms
            if preset.curveEnabled {
                self.applyCurveIfNeeded(force: true)
            } else {
                for fan in self.fans {
                    switch preset.modes[fan.index] ?? .auto {
                    case .auto: self.applyAuto(index: fan.index)
                    case .full: self.applyFixed(index: fan.index, rpm: fan.maxRPM)
                    case .fixed: self.applyFixed(index: fan.index, rpm: preset.rpms[fan.index] ?? fan.currentRPM)
                    }
                }
            }
            self.activePresetName = preset.name
        }
    }

    /// Called on quit: a forced fan must never outlive the app.
    @discardableResult
    func restoreSystemControl() -> Bool {
        sessionCooling = false
        modesBeforeSession.removeAll()
        lastAppliedFixed.removeAll()
        lastCurveWrite.removeAll()
        // Cancels the pending endSessionCooling closure before handing back.
        // Unlike UI telemetry, recovery must not omit a fan whose RPM read fails.
        let rawCount = try? SMC.shared.readDouble("FNum")
        let count: Int?
        if let rawCount, rawCount.isFinite, rawCount >= 0, rawCount <= 8,
           rawCount.rounded(.towardZero) == rawCount {
            count = Int(rawCount)
        } else {
            // Missing FNum is not proof of zero fans. Attempt all known indices,
            // but keep the outcome uncertain even if those writes succeed.
            count = nil
        }
        let restore: (Int) throws -> Void = { index in
            try self.writeMode(index: index, manual: false)
            if SMC.shared.keyInfo("F\(index)Md")?.isWritable == true {
                let mode = try SMC.shared.readDouble("F\(index)Md")
                guard mode.isFinite, mode == 0 else {
                    throw HelperError.smc(t("风扇恢复后仍未确认系统自动模式"))
                }
            } else {
                let flags = try SMC.shared.readDouble("FS! ")
                guard flags.isFinite, flags >= 0, flags <= 65535,
                      flags.rounded(.towardZero) == flags,
                      Int(flags) & (1 << (index * 2)) == 0 else {
                    throw HelperError.smc(t("风扇恢复后仍未确认系统自动模式"))
                }
            }
        }
        var failures = FanRecovery.restore(count: count, restoreAndVerify: restore)
        if count == nil {
            let known = Set(fans.map(\.index) + Array(modes.keys))
                .filter { (0..<8).contains($0) }.sorted()
            for index in known {
                do { try restore(index) }
                catch { failures.append("F\(index): \(error.localizedDescription)") }
            }
            failures[0] = t("无法确认风扇状态，请重试安全清理")
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "; ")
        ControlJournal.shared.record(ControlEvidence(
            operation: "fan.restore", backend: "smc",
            phase: failures.isEmpty ? .restored : .failed,
            target: count.map { "\($0) fan(s)" } ?? "unknown count",
            observed: failures.isEmpty ? "Md/FS! reports automatic" : nil,
            detail: failures.isEmpty ? nil : failures.joined(separator: "; ")))
        return failures.isEmpty
    }

    // 仅供更新取消的安全清理成功后调用；不写硬件，也不重放旧的固定/全速策略。
    func completeUpdateCancellation() {
        curveEnabled = false
        modes = Dictionary(uniqueKeysWithValues: Set(modes.keys).union(fans.map(\.index)).map { ($0, .auto) })
        sessionCooling = false
        modesBeforeSession.removeAll()
        lastAppliedFixed.removeAll()
        lastCurveWrite.removeAll()
        lastCurveTemperature = nil
        activePresetName = t("自动")
    }

    // MARK: - Persistence

    private func loadPersistedSettings() {
        if let data = defaults.data(forKey: Keys.modes),
           let decoded = try? JSONDecoder().decode([Int: FanMode].self, from: data) {
            modes = decoded
        }
        if let data = defaults.data(forKey: Keys.rpms),
           let decoded = try? JSONDecoder().decode([Int: Int].self, from: data) {
            fixedRPM = decoded
        }
        if let data = defaults.data(forKey: Keys.presets),
           let decoded = try? JSONDecoder().decode([FanPreset].self, from: data) {
            presets = decoded
        }
        curveEnabled = defaults.bool(forKey: Keys.curveEnabled)
        if let sensor = defaults.string(forKey: Keys.curveSensor) { curveSensorKey = sensor }
        let start = defaults.double(forKey: Keys.curveStart)
        if start > 0 { curveStartTemperature = start }
        let peak = defaults.double(forKey: Keys.curvePeak)
        if peak > 0 { curvePeakTemperature = peak }
        let mid = defaults.double(forKey: Keys.curveMid)
        if mid > 0 { curveMidTemperature = mid }
        if defaults.object(forKey: Keys.curveMidPercent) != nil {
            curveMidPercent = defaults.double(forKey: Keys.curveMidPercent)
        }
    }

    private func persistModes() {
        if let data = try? JSONEncoder().encode(modes) { defaults.set(data, forKey: Keys.modes) }
        if let data = try? JSONEncoder().encode(fixedRPM) { defaults.set(data, forKey: Keys.rpms) }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Keys.presets) }
    }

    private func fan(_ index: Int) -> FanInfo? {
        fans.first { $0.index == index }
    }

}
