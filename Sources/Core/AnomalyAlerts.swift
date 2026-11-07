import Foundation
import Combine

// MARK: - Pure sustained-condition state machine
struct AnomalyRule {
    let id: String
    let title: String
    let duration: TimeInterval
    var cooldown: TimeInterval = 3600
    /// What the banner tells the user to do. Fault rules share one sentence;
    /// 低电量 needs a different one, because there is nothing to inspect.
    var advice: String = "请检查连接和诊断信息；本提示不代表硬件故障"
    /// The request side of the evidence body. Fault rules quote the limit and
    /// phase; 低电量 quotes the lead time it was measured against.
    var requestLabel: String? = nil
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
        .init(id: "jump", title: "电量短时跳变", duration: 10),
        // Not a fault: this one is about the user, not the pack. 30 s of
        // sustained "about to run out" keeps a transient spike from firing it.
        // A 5 % floor also fires without any estimate, which is why the banner
        // text does not promise a number.
        //
        // 10 minutes rather than the default hour: the last stretch of a
        // discharge is exactly when one banner is not enough — if it is missed
        // at 20 minutes left, an hour of silence outlives the battery.
        .init(id: "lowPower", title: "电量即将用尽", duration: 30, cooldown: 600,
              advice: "请尽快接入电源或保存工作。剩余时间按最近的放电功率估算。",
              requestLabel: "提前提醒")
    ]

    /// Rolling discharge rate behind the 低电量 alert, so an estimate never
    /// hangs on a single 2 s sample.
    private var discharge = DischargeWatch()

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
                calibration: CalibrationEngine, fanError: String?,
                lowPowerLeadMinutes: Int = LowPowerPolicy.defaultLeadMinutes) {
        let now = battery.timestamp
        gate.beginSample(at: now)
        defer { previous = battery }
        guard battery.isPresent else {
            discharge.reset()
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

        // 低电量: only while the pack is the power source. On AC the remaining
        // runtime describes the charger, not the battery, and there is nothing
        // to warn about.
        //
        // Same current selection as the rest of the app: the filtered gauge value
        // lags load steps, so the instantaneous one is preferred when sane.
        let measuredAmps = abs(battery.instantAmperage) >= 0.02
            ? battery.instantAmperage : battery.amperage
        if !battery.isPluggedIn, drain {
            discharge.record(watts: battery.voltage * -measuredAmps, at: now)
        } else {
            discharge.reset()
        }
        let minutesLeft = battery.isPluggedIn
            ? nil
            : LowPowerPolicy.minutesLeft(remainingMAh: battery.currentCapacity,
                                         voltage: battery.voltage,
                                         watts: discharge.average(at: now) ?? 0)
        let lowPower = !battery.isPluggedIn
            && LowPowerPolicy.shouldWarn(minutesLeft: minutesLeft, lead: lowPowerLeadMinutes,
                                         percentage: battery.percentage)
        let lowPowerWatts = discharge.average(at: now)
        let lowPowerDetail = LowPowerPolicy.evidence(percentage: battery.percentage,
                                                    leadMinutes: lowPowerLeadMinutes,
                                                    averageWatts: lowPowerWatts,
                                                    minutesLeft: minutesLeft,
                                                    windowSeconds: Int(DischargeWatch.window))
        let lowPowerRecovery = LowPowerPolicy.shouldRecover(percentage: battery.percentage,
                                                            minutesLeft: minutesLeft,
                                                            lead: lowPowerLeadMinutes,
                                                            pluggedIn: battery.isPluggedIn)

        // Keyed by rule id rather than positionally zipped: a new rule can no longer
        // shift every fact below it onto the wrong rule, and a rule without a
        // fact is a compile-visible gap instead of a silent no-op.
        let facts: [String: (trigger: Bool, recover: Bool, detail: String)] = [
            "heat": (battery.temperature >= 40 && battery.temperature < 120, battery.temperature <= 38 || battery.temperature >= 120 || battery.temperature <= 0, String(format: "%.1f °C / ≥40°C / 300 s", battery.temperature)),
            "dcir": ((dcirRatio ?? 0) >= 1.3, dcirRatio == nil || (dcirRatio ?? 0) <= 1.15, "DCIR ratio=\(dcirRatio.map { String(format: "%.2f", $0) } ?? "--"); matched n=\(resistance.count)"),
            "capacity": (battery.maxCapacity > 0 && (ratio ?? 1) <= 0.9, ratio == nil || battery.maxCapacity <= 0 || (ratio ?? 1) >= 0.95, "FCC=\(battery.maxCapacity) mAh; baseline=\(reference ?? 0) mAh; days=\(baseline.count)"),
            "adapter": (deficit, !deficit, "Load=\(String(format: "%.1f", battery.systemLoad)) W; adapter=\(battery.adapter.watts) W; current=\(battery.amperage) A"),
            "acDrain": (unwantedDrain, !unwantedDrain, "AC=\(battery.isPluggedIn); current=\(String(format: "%.3f", battery.amperage)) A / 120 s"),
            "limit": (!suppressLimit && battery.isPluggedIn && battery.isCharging && battery.percentage >= limit + 3, suppressLimit || !battery.isPluggedIn || !battery.isCharging || battery.percentage <= limit + 1, "SOC=\(battery.percentage)%; limit=\(limit)%; charging=\(battery.isCharging)"),
            "calibration": (stalled, !stalled, "Phase=\(phase.rawValue); I=\(String(format: "%.3f", battery.amperage)) A / 180 s"),
            "fan": (fanError != nil, fanError == nil, fanError ?? "--"),
            "jump": (now < jumpUntil, now >= jumpUntil, jumpDetail),
            "lowPower": (lowPower, lowPowerRecovery, lowPowerDetail)
        ]
        assert(facts.count == Self.rules.count, "每条规则必须有对应的事实")
        for rule in Self.rules {
            guard let fact = facts[rule.id] else {
                assertionFailure("规则 \(rule.id) 没有事实，永远不会触发")
                continue
            }
            if gate.evaluate(rule, trigger: !disabled.contains(rule.id) && fact.trigger,
                             recover: disabled.contains(rule.id) || fact.recover, now: now) {
                let event = AnomalyEvidence(id: rule.id, title: rule.title, detail: fact.detail, date: now)
                events.removeAll { $0.id == rule.id }
                events.insert(event, at: 0)
                let requested = rule.requestLabel.map { "\(t($0))=\(lowPowerLeadMinutes) min / SOC=\(battery.percentage)%" }
                    ?? "Limit=\(limit)% / Phase=\(phase.rawValue)"
                Notifier.shared.post(key: "anomaly-" + rule.id, title: t(rule.title),
                                     body: Notifier.evidenceBody(t(rule.advice),
                                        requested: requested, actual: fact.detail, sampledAt: now),
                                     cooldown: rule.cooldown)
            }
        }
    }
}
