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
        case .charging: return "充电中"
        case .paused: return "充电已暂停"
        case .discharging: return "放电中"
        case .full: return "已充满"
        case .calibrating: return "校准中"
        case .noBattery: return "无电池"
        case .noAdapter: return "未接电源"
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
        case .chargeToFull: return "充电至 100%"
        case .dischargeToTen: return "放电至 10%"
        case .chargeToFullAgain: return "充电至 100%"
        case .hold: return "保持"
        case .dischargeToLimit: return "放电到 80%"
        }
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
        case .topUp: return "充满"
        case .stopCharging: return "暂停充电"
        case .startDischarge: return "开始放电"
        case .calibrate: return "启动校准模式"
        case .setLimit: return "设置充电限制"
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
        if weekdays.count == 7 { return "每天" }
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        return weekdays.sorted().map { "周" + names[$0 - 1] }.joined(separator: " ")
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
