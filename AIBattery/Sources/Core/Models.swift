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

enum MagSafeLED: Int, CaseIterable, Identifiable {
    case system = 0
    case off = 1
    case green = 2
    case orange = 3
    case blinkOrange = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .system: return "系统控制"
        case .off: return "始终关闭"
        case .green: return "始终绿色"
        case .orange: return "始终橙色"
        case .blinkOrange: return "闪烁橙色"
        }
    }
}

enum MenuBarItem: String, CaseIterable, Identifiable {
    case maxCapacity, macOSCondition, cycleCount
    case hardwarePercentage, temperature, timeRemaining, current, voltage
    case adapterCurrent, adapterVoltage, adapterPower
    case calibration, heatProtection, sailing, topUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maxCapacity: return "最大容量"
        case .macOSCondition: return "macOS 条件"
        case .cycleCount: return "循环"
        case .hardwarePercentage: return "硬件电池百分比"
        case .temperature: return "温度"
        case .timeRemaining: return "满载/剩余时间"
        case .current: return "电流"
        case .voltage: return "电压"
        case .adapterCurrent: return "电流"
        case .adapterVoltage: return "电压"
        case .adapterPower: return "电源"
        case .calibration: return "校准模式"
        case .heatProtection: return "过热保护"
        case .sailing: return "航海模式"
        case .topUp: return "充满"
        }
    }

    var symbol: String {
        switch self {
        case .maxCapacity: return "heart.text.square"
        case .macOSCondition: return "staroflife"
        case .cycleCount: return "clock.arrow.circlepath"
        case .hardwarePercentage: return "info.circle"
        case .temperature: return "thermometer"
        case .timeRemaining: return "clock"
        case .current, .adapterCurrent: return "bolt.horizontal"
        case .voltage, .adapterVoltage: return "bolt"
        case .adapterPower: return "powerplug"
        case .calibration: return "wrench.and.screwdriver"
        case .heatProtection: return "flame"
        case .sailing: return "sailboat"
        case .topUp: return "plus.circle"
        }
    }

    var category: String {
        switch self {
        case .maxCapacity, .macOSCondition, .cycleCount: return "电池健康"
        case .hardwarePercentage, .temperature, .timeRemaining, .current, .voltage: return "电池规格"
        case .adapterCurrent, .adapterVoltage, .adapterPower: return "电源适配器规格"
        default: return "AIBattery 状态"
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
    var note: String = ""
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
