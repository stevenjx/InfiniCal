import Foundation
import Combine

// MARK: - Pure sustained-condition state machine
struct AnomalyRule {
    let id: String
    let title: String
    let duration: TimeInterval
    var cooldown: TimeInterval = 3600
}

struct AnomalyGate {
    private var since: [String: Date] = [:]
    private var active: Set<String> = []
    private var ignored: Set<String> = []
    private var posted: [String: Date] = [:]
    private var lastSample: Date?

    mutating func beginSample(at now: Date) {
        if let last = lastSample, now.timeIntervalSince(last) > 10 || now < last {
            since.removeAll()
            active.removeAll()
            ignored.removeAll()
        }
        lastSample = now
    }

    mutating func ignore(_ id: String) { ignored.insert(id) }

    /// `recover` is separate from `trigger`, allowing a dead zone for hysteresis.
    mutating func evaluate(_ rule: AnomalyRule, trigger: Bool, recover: Bool, now: Date) -> Bool {
        if recover {
            since[rule.id] = nil
            active.remove(rule.id)
            ignored.remove(rule.id)
            return false
        }
        if trigger {
            since[rule.id] = since[rule.id] ?? now
            if now.timeIntervalSince(since[rule.id]!) >= rule.duration { active.insert(rule.id) }
        } else if !active.contains(rule.id) {
            since[rule.id] = nil
        }
        guard active.contains(rule.id), !ignored.contains(rule.id),
              posted[rule.id].map({ now.timeIntervalSince($0) >= rule.cooldown }) ?? true else { return false }
        posted[rule.id] = now
        return true
    }
}

struct AnomalyEvidence: Identifiable {
    let id: String
    let title: String
    let detail: String
    let date: Date
}

final class AnomalyAlerts: ObservableObject {
    static let shared = AnomalyAlerts()
    @Published private(set) var events: [AnomalyEvidence] = []
    @Published private(set) var disabled: Set<String>
    private var gate = AnomalyGate()
    private var previous: BatterySnapshot?
    private var jumpUntil = Date.distantPast
    private var jumpDetail = ""
    private let defaults = UserDefaults.standard

    static let rules: [AnomalyRule] = [
        .init(id: "heat", title: "电池持续高温", duration: 300),
        .init(id: "dcir", title: "可比测量内阻上升", duration: 60),
        .init(id: "capacity", title: "系统满充容量下降", duration: 300),
        .init(id: "adapter", title: "适配器供电可能不足", duration: 120),
        .init(id: "acDrain", title: "接电时电池持续放电", duration: 120),
        .init(id: "limit", title: "充电超过设定上限", duration: 120),
        .init(id: "calibration", title: "校准阶段未检测到预期电流", duration: 180),
        .init(id: "fan", title: "风扇控制持续失败", duration: 30),
        .init(id: "jump", title: "电量短时跳变", duration: 10)
    ]

    private init() { disabled = Set(UserDefaults.standard.stringArray(forKey: "disabledAnomalyAlerts") ?? []) }

    func ignore(_ id: String) {
        gate.ignore(id)
        events.removeAll { $0.id == id }
    }
    func setDisabled(_ id: String, _ value: Bool) {
        if value { disabled.insert(id); ignore(id) } else { disabled.remove(id) }
        defaults.set(disabled.sorted(), forKey: "disabledAnomalyAlerts")
    }

    func sample(_ battery: BatterySnapshot, limit: Int, intentionalDrain: Bool, suppressLimit: Bool,
                calibration: CalibrationEngine, fanError: String?) {
        let now = battery.timestamp
        gate.beginSample(at: now)
        defer { previous = battery }
        guard battery.isPresent else {
            for rule in Self.rules { _ = gate.evaluate(rule, trigger: false, recover: true, now: now) }
            return
        }
        let drain = battery.instantAmperage < -0.05 && battery.amperage < -0.05
        let unwantedDrain = battery.isPluggedIn && drain && !intentionalDrain
        if let old = previous, now.timeIntervalSince(old.timestamp) > 0,
           now.timeIntervalSince(old.timestamp) <= 10, abs(battery.percentage - old.percentage) >= 5 {
            jumpUntil = now.addingTimeInterval(30)
            jumpDetail = "\(old.percentage)% → \(battery.percentage)% / \(Int(now.timeIntervalSince(old.timestamp))) s"
        }
        let baseline = DailyHistory.shared.days.filter { $0.day < Calendar.current.startOfDay(for: now) }
            .suffix(7).compactMap { $0.reportedCapacityMAh }.filter { $0 > 0 }.sorted()
        let reference = baseline.isEmpty ? nil : baseline[baseline.count / 2]
        let ratio = baseline.count >= 3 ? reference.map { Double(battery.maxCapacity) / Double($0) } : nil
        let window = HealthWindow(days: [], records: calibration.records, count: 90, now: now)
        let resistance = window.comparableRecords.filter { $0.internalResistanceMilliohm.isFinite && $0.internalResistanceMilliohm > 0 }
        let dcirRatio: Double? = resistance.count >= 2 ? resistance.last!.internalResistanceMilliohm / resistance[resistance.count - 2].internalResistanceMilliohm : nil
        let phase = calibration.phase
        let expectedDischarge = calibration.isRunning && (phase == .discharging || phase == .dischargingToBuffer)
        let expectedCharge = calibration.isRunning && (phase == .chargingToFull || phase == .rechargingToFull)
            && battery.percentage < 95 && battery.isPluggedIn
        let stalled = (expectedDischarge && !drain) || (expectedCharge && battery.amperage <= 0.05)
        let deficit = unwantedDrain && battery.adapter.watts > 0 && battery.systemLoad.isFinite
            && battery.systemLoad > Double(battery.adapter.watts) + 5
        let facts: [(Bool, Bool, String)] = [
            (battery.temperature >= 40 && battery.temperature < 120, battery.temperature <= 38 || battery.temperature >= 120 || battery.temperature <= 0, String(format: "%.1f °C / ≥40°C / 300 s", battery.temperature)),
            ((dcirRatio ?? 0) >= 1.3, dcirRatio == nil || (dcirRatio ?? 0) <= 1.15, "DCIR ratio=\(dcirRatio.map { String(format: "%.2f", $0) } ?? "--"); matched n=\(resistance.count)"),
            (battery.maxCapacity > 0 && (ratio ?? 1) <= 0.9, ratio == nil || battery.maxCapacity <= 0 || (ratio ?? 1) >= 0.95, "FCC=\(battery.maxCapacity) mAh; baseline=\(reference ?? 0) mAh; days=\(baseline.count)"),
            (deficit, !deficit, "Load=\(String(format: "%.1f", battery.systemLoad)) W; adapter=\(battery.adapter.watts) W; current=\(battery.amperage) A"),
            (unwantedDrain, !unwantedDrain, "AC=\(battery.isPluggedIn); current=\(String(format: "%.3f", battery.amperage)) A / 120 s"),
            (!suppressLimit && battery.isPluggedIn && battery.isCharging && battery.percentage >= limit + 3, suppressLimit || !battery.isPluggedIn || !battery.isCharging || battery.percentage <= limit + 1, "SOC=\(battery.percentage)%; limit=\(limit)%; charging=\(battery.isCharging)"),
            (stalled, !stalled, "Phase=\(phase.rawValue); I=\(String(format: "%.3f", battery.amperage)) A / 180 s"),
            (fanError != nil, fanError == nil, fanError ?? "--"),
            (now < jumpUntil, now >= jumpUntil, jumpDetail)
        ]
        for (rule, fact) in zip(Self.rules, facts) {
            if gate.evaluate(rule, trigger: !disabled.contains(rule.id) && fact.0,
                             recover: disabled.contains(rule.id) || fact.1, now: now) {
                let event = AnomalyEvidence(id: rule.id, title: rule.title, detail: fact.2, date: now)
                events.removeAll { $0.id == rule.id }
                events.insert(event, at: 0)
                Notifier.shared.post(key: "anomaly-" + rule.id, title: t(rule.title),
                                     body: Notifier.evidenceBody(t("请检查连接和诊断信息；本提示不代表硬件故障"),
                                        requested: "Limit=\(limit)% / Phase=\(phase.rawValue)", actual: fact.2, sampledAt: now), cooldown: rule.cooldown)
            }
        }
    }
}
