//
//  Advice.swift
//  Local, evidence-based maintenance advice.
//
//  Pure logic: the caller hands over plain day and session values, the engine
//  returns advice items that each carry their own evidence. Nothing here reads
//  the disk, the network or the hardware, and nothing is inferred when the data
//  is too thin — an empty report is a valid answer.
//
//  Wording rule: an item states what was measured and what could be done about
//  it. It never claims a fault, a diagnosis or a health effect that the numbers
//  do not show.
//

import Foundation

struct AdviceInput: Equatable {

    struct Day: Equatable {
        var date: Date
        /// Seconds at or above 40 °C while the app was observing.
        var highTemperatureSeconds: Double = 0
        var maxTemperature: Double = 0
        var maxPercentage: Int = 0
        var pluggedSeconds: Double = 0
        /// Seconds the app actually observed that day; 0 means "no data".
        var observedSeconds: Double = 0
    }

    struct Session: Equatable {
        var date: Date
        var capacityMAh: Double = 0
        var resistanceMilliohm: Double = 0
        var healthPercent: Double = 0
        var cycleCount: Int = 0
        /// `CalibrationPreset.rawValue` when the record carries one.
        var preset: String?
        /// Where the pack started, used to recognise a deep run on legacy records.
        var startPercentage: Int = 100
        var eligible: Bool = false
    }

    var days: [Day] = []
    var sessions: [Session] = []
    /// Current charge ceiling; 100 means "no ceiling", so overshoot is moot.
    var chargeLimit: Int = 100
    var now: Date = Date()
}

struct AdviceItem: Identifiable, Equatable {
    enum Level: String, Codable {
        case attention
        case suggestion
    }

    var id: String
    var level: Level
    var title: String
    var advice: String
    /// Never empty: an item without evidence is not published.
    var evidence: [String]
}

struct AdviceReport: Equatable {
    var items: [AdviceItem] = []
    var observedDays: Int = 0
    var eligibleSessions: Int = 0
    var windowDays: Int = AdviceEngine.windowDays
    var generatedAt: Date = Date()
}

enum AdviceEngine {

    static let windowDays = 30
    static let sessionWindowDays = 180
    /// Ten hours above 40 °C in a month is the point where the suggestion is
    /// worth making; below that the advice would fire on every warm afternoon.
    static let highTemperatureHours = 10.0
    static let minimumObservedDays = 7
    static let overshootMargin = 5
    static let overshootDays = 3
    static let resistanceRise = 0.15
    static let deepCalibrationCooldownDays = 30
    static let minimumSessions = 3

    static func evaluate(_ input: AdviceInput) -> AdviceReport {
        let days = input.days
            .filter { $0.observedSeconds > 0 && $0.date <= input.now }
            .filter { input.now.timeIntervalSince($0.date) <= Double(windowDays) * 86400 }
            .sorted { $0.date < $1.date }
        let sessions = input.sessions
            .filter { $0.eligible && $0.date <= input.now }
            .filter { input.now.timeIntervalSince($0.date) <= Double(sessionWindowDays) * 86400 }
            .sorted { $0.date < $1.date }

        var items: [AdviceItem] = []
        if let item = highTemperature(days) { items.append(item) }
        if let item = limitOvershoot(days, limit: input.chargeLimit) { items.append(item) }
        if let item = resistanceRise(sessions) { items.append(item) }
        if let item = deepCalibrationCooldown(input.sessions, now: input.now) { items.append(item) }
        items.sort { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level == .attention }
            return lhs.id < rhs.id
        }
        return AdviceReport(items: items, observedDays: days.count,
                            eligibleSessions: sessions.count,
                            windowDays: windowDays, generatedAt: input.now)
    }

    // MARK: - Rules

    /// Sustained heat is the one condition the app can measure cheaply and that
    /// the user can act on directly.
    private static func highTemperature(_ days: [AdviceInput.Day]) -> AdviceItem? {
        guard days.count >= minimumObservedDays else { return nil }
        let seconds = days.reduce(0) { $0 + max(0, $1.highTemperatureSeconds) }
        let hours = seconds / 3600
        guard hours >= highTemperatureHours else { return nil }
        let minutesPerDay = Int((seconds / 60 / Double(days.count)).rounded())
        let peak = days.map(\.maxTemperature).max() ?? 0
        return AdviceItem(
            id: "high-temperature",
            level: .attention,
            title: t("高温时长偏高"),
            advice: t("把充电和校准安排在阴凉处，避免边充边跑重负载；高温时优先暂停充电。"),
            evidence: [
                tf("近 30 天有记录 {p} 天", "\(days.count)"),
                tf("40°C 以上累计 {p} 小时（平均每天 {p} 分钟）",
                   String(format: "%.1f", hours), "\(minutesPerDay)"),
                tf("期间最高温度 {p}°C", String(format: "%.1f", peak)),
            ])
    }

    /// A ceiling that is written but not held is the failure users notice last.
    /// Only days with the adapter connected count, so a deliberate unplugged
    /// discharge is not mistaken for an ineffective limit.
    private static func limitOvershoot(_ days: [AdviceInput.Day], limit: Int) -> AdviceItem? {
        guard limit > 0, limit < 100, days.count >= minimumObservedDays else { return nil }
        let threshold = limit + overshootMargin
        let over = days.filter { $0.pluggedSeconds > 0 && $0.maxPercentage >= threshold }
        guard over.count >= overshootDays else { return nil }
        let peak = over.map(\.maxPercentage).max() ?? threshold
        return AdviceItem(
            id: "limit-overshoot",
            level: .attention,
            title: t("充电上限可能未持续生效"),
            advice: t("改用系统充电上限或打开周期回读；写入成功不等于持续生效。"),
            evidence: [
                tf("充电上限设为 {p}%", "\(limit)"),
                tf("最近 30 天有 {p} 天在插电时超过 {p}%，最高 {p}%",
                   "\(over.count)", "\(threshold)", "\(peak)"),
                t("如果这些天没有手动充满，说明上限没有持续生效。"),
            ])
    }

    /// Resistance is only comparable between similar runs, so the item says so
    /// instead of presenting the number as a health verdict.
    private static func resistanceRise(_ sessions: [AdviceInput.Session]) -> AdviceItem? {
        let usable = sessions.filter { $0.resistanceMilliohm > 0 && $0.capacityMAh > 0 }
        guard usable.count >= minimumSessions,
              let first = usable.first, let last = usable.last,
              first.resistanceMilliohm > 0 else { return nil }
        let rise = (last.resistanceMilliohm - first.resistanceMilliohm) / first.resistanceMilliohm
        guard rise >= resistanceRise else { return nil }
        let percent = String(format: "+%.0f%%", rise * 100)
        return AdviceItem(
            id: "resistance-rise",
            level: .attention,
            title: t("内阻上升较快"),
            advice: t("先减少深度放电与高温时段，再在下一次标准校准后复查。"),
            evidence: [
                tf("有效校准 {p} 次（{p} 至 {p}）", "\(usable.count)",
                   day(first.date), day(last.date)),
                tf("内阻从 {p} mΩ 变为 {p} mΩ（{p}）",
                   String(format: "%.1f", first.resistanceMilliohm),
                   String(format: "%.1f", last.resistanceMilliohm), percent),
                tf("同期循环数增加 {p}", "\(max(0, last.cycleCount - first.cycleCount))"),
                t("内阻受温度与放电功率影响，只有条件相近的记录才可直接比较。"),
            ])
    }

    /// A deep run costs a full cycle and tells you little a standard run would
    /// not; repeating it inside a month is the advice worth giving.
    private static func deepCalibrationCooldown(_ sessions: [AdviceInput.Session],
                                                now: Date) -> AdviceItem? {
        let deep = sessions.filter { $0.date <= now }
            .filter { $0.preset == "deep" || $0.startPercentage <= 15 }
            .sorted { $0.date > $1.date }
        guard let last = deep.first,
              now.timeIntervalSince(last.date) <= Double(deepCalibrationCooldownDays) * 86400
        else { return nil }
        let daysAgo = max(0, Int((now.timeIntervalSince(last.date) / 86400).rounded()))
        return AdviceItem(
            id: "deep-calibration-cooldown",
            level: .suggestion,
            title: t("近期不建议再次深度校准"),
            advice: t("需要复查时先用快速检查或标准预设。"),
            evidence: [
                tf("最近一次深度校准在 {p}（{p} 天前）", day(last.date), "\(daysAgo)"),
                t("深度校准会把电池放到接近空电，短期内重复做不会带来更多信息。"),
            ])
    }

    // MARK: - Helpers

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}
