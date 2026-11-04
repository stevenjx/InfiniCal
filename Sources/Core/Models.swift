//
//  Models.swift
//  Shared model types.
//

import Foundation
import SwiftUI

enum ChargeState: String {
    case charging
    case paused
    case discharging
    case full
    case calibrating
    case noBattery
    case noAdapter

    var title: String {
        switch self {
        case .charging: return t("充电中")
        case .paused: return t("充电已暂停")
        case .discharging: return t("放电中")
        case .full: return t("已充满")
        case .calibrating: return t("校准中")
        case .noBattery: return t("无电池")
        case .noAdapter: return t("未接电源")
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .paused: return "pause.fill"
        case .discharging: return "arrow.down"
        case .full: return "checkmark"
        case .calibrating: return "wrench.and.screwdriver"
        case .noBattery: return "battery.0"
        case .noAdapter: return "powerplug"
        }
    }
}

enum CalibrationStage: Int, CaseIterable {
    case chargeToFull
    case dischargeToTen
    case chargeToFullAgain
    case hold
    case dischargeToLimit

    var title: String {
        switch self {
        case .chargeToFull: return t("充电至 100%")
        case .dischargeToTen: return t("放电至 10%")
        case .chargeToFullAgain: return t("充电至 100%")
        case .hold: return t("保持")
        case .dischargeToLimit: return t("放电到 80%")
        }
    }
}

/// Pure hysteresis decision, independent of hardware writes and UI state.
enum ChargePolicy {
    static func allowsCharging(percentage: Int, limit: Int, sailing: Bool,
                               difference: Int, previous: Bool?, isCharging: Bool) -> Bool {
        if percentage >= limit { return false }
        if !sailing { return true }
        let floor = max(1, limit - max(1, min(30, difference)))
        if percentage <= floor { return true }
        return previous ?? isCharging
    }
}

/// Turns a process's CPU share into watts and extra runtime.
///
/// `ps -o pcpu` reports 100 % per full core, so the share of the whole CPU is
/// the percentage over `100 × cores`. Multiplying by the measured CPU power
/// gives the process's watts. The runtime gain is the difference between the
/// current estimate and the estimate without that load, and is only meaningful
/// on battery — on AC the saving is wall power, so callers pass no hours.
enum PowerAttribution {
    struct Result: Equatable {
        var watts: Double
        var gainMinutes: Int
    }

    static func attribute(cpuPercent: Double, cores: Int, cpuWatts: Double,
                          currentWatts: Double, fullCapacityHours: Double?) -> Result {
        let coreCount = Double(max(cores, 1))
        guard cpuWatts.isFinite, cpuWatts > 0,
              cpuPercent.isFinite, cpuPercent > 0,
              currentWatts.isFinite, currentWatts > 0,
              let fullHours = fullCapacityHours, fullHours.isFinite, fullHours > 0 else {
            return Result(watts: 0, gainMinutes: 0)
        }
        let share = min(1, cpuPercent / (100 * coreCount))
        let watts = cpuWatts * share
        // Removing the whole load cannot make the draw negative, so floor the
        // remaining power rather than reporting an impossible runtime.
        let reduced = fullHours * currentWatts / max(0.5, currentWatts - watts)
        let gain = Int(((reduced - fullHours) * 60).rounded())
        return Result(watts: watts, gainMinutes: max(0, gain))
    }
}

struct CalibrationRun {
    var stage: CalibrationStage = .chargeToFull
    var startedAt = Date()
    var holdUntil: Date?
}

enum TaskKind: String, Codable, CaseIterable {
    case topUp, stopCharging, startDischarge, calibrate, setLimit

    var title: String {
        switch self {
        case .topUp: return t("充满")
        case .stopCharging: return t("暂停充电")
        case .startDischarge: return t("开始放电")
        case .calibrate: return t("启动校准模式")
        case .setLimit: return t("设置充电限制")
        }
    }

    var symbol: String {
        switch self {
        case .topUp: return "plus.circle"
        case .stopCharging: return "pause.circle"
        case .startDischarge: return "arrow.down.circle"
        case .calibrate: return "wrench.and.screwdriver"
        case .setLimit: return "slider.horizontal.3"
        }
    }
}

struct ScheduledTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: TaskKind = .topUp
    var value: Int = 80
    var hour: Int = 9
    var minute: Int = 0
    /// 1 = Monday ... 7 = Sunday
    var weekdays: Set<Int> = Set(1...7)
    var enabled: Bool = true
    var lastRun: Date?
    /// Guards the task must pass before it runs. Optional so tasks saved by an
    /// older version still decode and behave exactly as they used to.
    var conditions: TaskConditions?

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var weekdayText: String {
        if weekdays.count == 7 { return t("每天") }
        let names = [t("一"), t("二"), t("三"), t("四"), t("五"), t("六"), t("日")]
        return weekdays.sorted().map { t("周") + names[$0 - 1] }.joined(separator: " ")
    }
}

/// A guard a task has to pass before it runs. Every field is optional, so a
/// task with no conditions behaves exactly as it did before and older journals
/// still decode.
struct TaskConditions: Codable, Equatable {
    /// 只在电量低于该值时执行。
    var onlyBelowPercentage: Int?
    /// 只在连接充电器时执行。
    var onlyOnAdapter: Bool?
    /// 电池温度达到该值（°C）时跳过。
    var maxTemperature: Int?
}

/// Where a control request came from. Automation must not mistake its own
/// writes for the user's, which is what the manual-override rule depends on.
enum ControlOrigin {
    case user, scheduled, automatic
}

enum TaskOutcome: String, Codable {
    case executed, skipped
}

/// One tick's worth of machine state. Plain values, so the scheduling decision
/// stays a pure function that can be tested without a real battery.
struct TaskContext: Equatable {
    struct ManualOverride: Equatable {
        var kind: TaskKind
        var at: Date
    }

    var percentage: Int = 0
    var temperature: Double = 0
    var onAdapter: Bool = false
    var manualOverride: ManualOverride?
    var now: Date = Date()
}

/// How scheduled tasks compete when they come due together.
///
/// The ordering is safety-first: anything that *holds charging off* outranks
/// anything that *starts* it, a calibration session outranks a scalar ceiling
/// because it drives that ceiling itself, and a one-off top-up is the easiest
/// thing to postpone.
enum TaskPolicy {
    enum Verdict: Equatable {
        case run
        case skipped(String)
    }

    struct Decision: Equatable {
        var task: ScheduledTask
        var verdict: Verdict
    }

    /// A manual change of the same lever is respected for this long. Automation
    /// should not undo something the user just did by hand.
    static let manualOverrideWindow: TimeInterval = 30 * 60

    /// Lower wins.
    static func rank(_ kind: TaskKind) -> Int {
        switch kind {
        case .stopCharging: return 0
        case .startDischarge: return 1
        case .calibrate: return 2
        case .setLimit: return 3
        case .topUp: return 4
        }
    }

    /// Which lever a task pulls. Two tasks on the same lever cannot both take
    /// effect at one moment, so the lower-ranked one waits. A ceiling is its own
    /// lever: it is a persistent setting, and a top-up even depends on it —
    /// that is the value the top-up restores afterwards.
    enum Lever {
        case chargeDirection, ceiling
    }

    static func lever(_ kind: TaskKind) -> Lever {
        switch kind {
        case .topUp, .stopCharging, .startDischarge, .calibrate: return .chargeDirection
        case .setLimit: return .ceiling
        }
    }

    /// Decide every due task in one pass. Results come back in execution order,
    /// so a caller can simply apply them top to bottom.
    static func decide(_ due: [ScheduledTask], context: TaskContext) -> [Decision] {
        let ordered = due.sorted { lhs, rhs in
            let left = rank(lhs.kind), right = rank(rhs.kind)
            if left != right { return left < right }
            if lhs.timeText != rhs.timeText { return lhs.timeText < rhs.timeText }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var accepted: [ScheduledTask] = []
        var decisions: [Decision] = []
        for task in ordered {
            if let reason = skipReason(task, context: context, accepted: accepted) {
                decisions.append(Decision(task: task, verdict: .skipped(reason)))
            } else {
                accepted.append(task)
                decisions.append(Decision(task: task, verdict: .run))
            }
        }
        return decisions
    }

    private static func skipReason(_ task: ScheduledTask, context: TaskContext,
                                   accepted: [ScheduledTask]) -> String? {
        let conditions = task.conditions ?? TaskConditions()
        if conditions.onlyOnAdapter == true, !context.onAdapter {
            return t("未连接充电器")
        }
        if let limit = conditions.onlyBelowPercentage, context.percentage >= limit {
            return tf("电量 {p}% 不低于 {p}%，本次跳过", "\(context.percentage)", "\(limit)")
        }
        if let limit = conditions.maxTemperature, context.temperature >= Double(limit) {
            let actual = "\(Int(context.temperature.rounded()))"
            return tf("电池温度 {p}°C 已达上限 {p}°C，本次跳过", actual, "\(limit)")
        }
        if let manual = context.manualOverride,
           lever(manual.kind) == lever(task.kind),
           context.now.timeIntervalSince(manual.at) < manualOverrideWindow {
            let minutes = max(1, Int(context.now.timeIntervalSince(manual.at) / 60))
            return tf("你 {p} 分钟前手动操作过，本次不覆盖", "\(minutes)")
        }
        if let winner = accepted.first(where: { lever($0.kind) == lever(task.kind) }) {
            return tf("与「{p}」同时到点，它优先", winner.kind.title)
        }
        return nil
    }
}

struct TaskLogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    /// Nil for entries written before outcomes were distinguished.
    var outcome: TaskOutcome?
}

struct HistoryPoint: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var value: Double

    init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

struct HistoryBuffers {
    var battery: [HistoryPoint] = []
    var temperature: [HistoryPoint] = []
    var power: [HistoryPoint] = []
    var capacity: [HistoryPoint] = []

    mutating func append(battery: Double, temperature: Double, power: Double,
                         capacity: Double, limit: Int) {
        let now = Date()
        self.battery.append(HistoryPoint(date: now, value: battery))
        self.temperature.append(HistoryPoint(date: now, value: temperature))
        self.power.append(HistoryPoint(date: now, value: power))
        self.capacity.append(HistoryPoint(date: now, value: capacity))
        let cutoff = now.addingTimeInterval(-60 * 60 * 3)
        self.battery.removeAll { $0.date < cutoff }
        self.temperature.removeAll { $0.date < cutoff }
        self.power.removeAll { $0.date < cutoff }
        self.capacity.removeAll { $0.date < cutoff }
    }
}

struct HighUsageApp: Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    /// CPU percentage as reported by `ps -o pcpu`, i.e. 100 = one full core.
    var energyImpact: Double
    var icon: NSImage?
    /// Estimated watts this process is responsible for, derived from its share
    /// of total CPU capacity and the measured CPU power. Zero when no
    /// measurement was available, so the UI can omit the figure instead of
    /// inventing one.
    var estimatedWatts: Double = 0
    /// Extra battery minutes if this process stopped, at the current draw.
    var estimatedGainMinutes: Int = 0
}
