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

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var weekdayText: String {
        if weekdays.count == 7 { return t("每天") }
        let names = [t("一"), t("二"), t("三"), t("四"), t("五"), t("六"), t("日")]
        return weekdays.sorted().map { t("周") + names[$0 - 1] }.joined(separator: " ")
    }
}

struct TaskLogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
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
    var energyImpact: Double
    var icon: NSImage?
}
