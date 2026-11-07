//
//  HealthReport.swift
//  A battery report someone can actually send.
//
//  The app already has every number, spread across four pages. What it did not
//  have was one file a person can attach to a support ticket, hand to a buyer,
//  or keep before sending a machine in for service. TXT and CSV are for
//  machines; this is for the other reader.
//
//  Drawn with Core Graphics and Core Text rather than `ImageRenderer`, for two
//  reasons: `ImageRenderer` needs macOS 13 while this app supports 12, and a
//  vector PDF stays sharp at any zoom while a rendered bitmap does not. Core
//  Text also embeds the system Chinese font, so no glyph turns into a box.
//
//  Content rule, same as everywhere else: a section with no data says so. It
//  does not print zeros that would read as a measurement.
//

import Foundation
import CoreGraphics
import AppKit

// MARK: - Input

/// Everything the report draws, as plain values.
///
/// Collected once by `HealthReportData.collect()` so the layout code never
/// touches a store, a sensor or the clock.
struct HealthReportData {
    var generatedAt = Date()
    var appVersion = ""
    var model = ""
    var osVersion = ""
    var architecture = ""

    var percentage = 0
    var healthPercent = 0
    var designCapacityMAh = 0
    var maxCapacityMAh = 0
    var cycleCount = 0
    var temperature = 0.0
    var condition = ""
    var chargeLimit = 80
    var strategy = ""

    /// Daily rows inside the report window, oldest first.
    var days: [DailyStat] = []
    /// Calibration records, oldest first.
    var records: [CalibrationRecord] = []
    /// Plug-in sessions inside the window, newest first.
    var sessions: [ChargeSession] = []
    var habitFindings: [ChargeHabitFinding] = []
    var sleepSummary: SleepAnalyzer.Summary?
    /// Rows for the sleep table, newest first.
    var sleeps: [SleepSession] = []
    var trend: BatteryTrend?

    /// 90 days: enough to show a slope, short enough to fit on one page.
    static let windowDays = 90

    var isEmpty: Bool { days.isEmpty && records.isEmpty }
}

enum HealthReportCollector {

    /// Reads the stores and the current snapshot. Called from the UI, where a
    /// disk read and an SMC read are both expected.
    static func collect(now: Date = Date()) -> HealthReportData {
        let state = AppState.shared
        let snapshot = state.snapshot
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -HealthReportData.windowDays, to: now) ?? now
        let days = DailyHistory.shared.days
            .filter { $0.day >= start && $0.day <= now && !$0.isEmpty }
            .sorted { $0.day < $1.day }
        let records = CalibrationStore.load()
            .filter { $0.endDate <= now }
            .sorted { $0.endDate < $1.endDate }
        let habit = ChargeHabitAnalyzer.analyze(ChargeSessionStore.shared.sessions, now: now)

        var data = HealthReportData()
        data.generatedAt = now
        data.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        data.model = SysInfo.machineModel()
        data.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        data.architecture = SysInfo.architecture()
        data.percentage = snapshot.percentage
        data.healthPercent = snapshot.healthPercent
        data.designCapacityMAh = snapshot.designCapacity
        data.maxCapacityMAh = snapshot.maxCapacity
        data.cycleCount = snapshot.cycleCount
        data.temperature = snapshot.temperature
        data.condition = snapshot.conditionText
        data.chargeLimit = state.chargeVal
        data.strategy = state.capabilities.strategy.title
        data.days = days
        data.records = records
        data.sessions = habit.sessions
        data.habitFindings = habit.findings
        data.sleepSummary = SleepAnalyzer.summarize(SleepSessionStore.shared.sessions, now: now)
        data.sleeps = SleepAnalyzer.recent(SleepSessionStore.shared.sessions, limit: 6, now: now)
        data.trend = BatteryTrend.compute(days: days)
        return data
    }
}

/// Small identity helpers the report needs; the diagnostics view has its own
/// copy for its own format, and duplicating two `sysctl` calls is cheaper than
/// making one view depend on the other.
enum SysInfo {
    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "--" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

// MARK: - Report

enum HealthReport {

    static func makePDF(_ data: HealthReportData) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: PDFCanvas.pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let canvas = PDFCanvas(context: context)
        drawCover(data, on: canvas)
        drawSummary(data, on: canvas)
        drawTrend(data, on: canvas)
        drawCalibration(data, on: canvas)
        drawHabits(data, on: canvas)
        canvas.finish()
        return output as Data
    }

    /// Section text is produced by pure functions so the wording can be checked
    /// without rendering a PDF.
    static func overviewLines(_ data: HealthReportData) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((t("最大容量"), "\(data.maxCapacityMAh) mAh"))
        rows.append((t("设计容量"), "\(data.designCapacityMAh) mAh"))
        rows.append((t("健康度"), data.maxCapacityMAh > 0 && data.designCapacityMAh > 0
                     ? String(format: "%.0f%%", Double(data.maxCapacityMAh) / Double(data.designCapacityMAh) * 100)
                     : "--"))
        rows.append((t("循环次数"), "\(data.cycleCount)"))
        rows.append((t("电池温度"), data.temperature > 0 ? String(format: "%.1f °C", data.temperature) : "--"))
        rows.append((t("系统状态"), data.condition.isEmpty ? "--" : data.condition))
        rows.append((t("充电上限"), "\(data.chargeLimit)%"))
        rows.append((t("控制后端"), data.strategy.isEmpty ? "--" : data.strategy))
        return rows
    }

    /// "数据不足" rather than an empty chart: a report with a blank section
    /// looks like a bug in the app, not like a machine that is two days old.
    static func trendNote(_ data: HealthReportData) -> String {
        let withCapacity = data.days.filter { ($0.reportedCapacityMAh ?? 0) > 0 }
        if data.days.isEmpty {
            return t("这个时间窗内没有任何按天记录。保持 InfiniCal 运行几天后重新生成即可。")
        }
        if withCapacity.count < 2 {
            return tf("这个时间窗内只有 {p} 天记录到满充容量，画不出趋势；以下只列出每日能耗。", "\(withCapacity.count)")
        }
        return tf("共 {p} 天记录，其中 {p} 天带系统满充容量。曲线为系统上报值，未经校准修正。",
                  "\(data.days.count)", "\(withCapacity.count)")
    }

    static func calibrationNote(_ data: HealthReportData) -> String {
        guard let last = data.records.last else {
            return t("没有已完成的校准记录。健康度一栏来自系统上报的满充容量，不是实测容量。")
        }
        let quality = last.quality?.label ?? t("未评估")
        return tf("最近一次校准：{p}，质量「{p}」。实测容量与内阻只在这类记录里出现。",
                  last.endDate.formatted(date: .abbreviated, time: .shortened), quality)
    }

    // MARK: Drawing

    private static func drawCover(_ data: HealthReportData, on canvas: PDFCanvas) {
        canvas.text(t("电池体检报告"), style: .init(size: 22, weight: .bold), gapAfter: 2)
        canvas.text(tf("生成于 {p}", data.generatedAt.formatted(date: .long, time: .shortened)),
                    style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 2)
        canvas.text("\(data.model) · \(data.architecture) · \(data.osVersion) · InfiniCal \(data.appVersion)",
                    style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 10)
        canvas.rule()
        canvas.text(t("本报告完全由本机数据生成，不包含序列号、用户名或文件路径，也未经云端处理。"),
                    style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 12)
    }

    private static func drawSummary(_ data: HealthReportData, on canvas: PDFCanvas) {
        canvas.heading(t("概览"))
        let design = Double(max(1, data.designCapacityMAh))
        let capacityFraction = Double(data.maxCapacityMAh) / design
        canvas.bar(fraction: capacityFraction,
                   label: t("最大容量 / 设计容量"),
                   value: String(format: "%d / %d mAh（%.0f%%）",
                                 data.maxCapacityMAh, data.designCapacityMAh, capacityFraction * 100),
                   tint: capacityFraction < 0.8 ? .systemOrange : .systemGreen)
        canvas.bar(fraction: Double(data.percentage) / 100,
                   label: t("当前电量"),
                   value: "\(data.percentage)%",
                   tint: .systemBlue)
        for (label, value) in overviewLines(data) {
            canvas.pair(label, value)
        }
        canvas.text(t("健康度是系统上报的满充容量除以设计容量；它与校准实测值不是同一个数，两者的差异在「校准记录」里给出。"),
                    style: .init(size: 8, color: PDFCanvas.Style.secondary), gapAfter: 12)
    }

    private static func drawTrend(_ data: HealthReportData, on canvas: PDFCanvas) {
        canvas.heading(t("容量与能耗趋势"))
        canvas.text(trendNote(data), style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 8)

        let capacity = data.days.compactMap { $0.reportedCapacityMAh.map(Double.init) }
        if capacity.count >= 2, let low = capacity.min(), let high = capacity.max() {
            let pad = Swift.max(10, (high - low) * 0.2)
            canvas.line(values: capacity, range: (low - pad)...(high + pad),
                        tint: .systemGreen,
                        caption: tf("系统满充容量 {p} → {p} mAh（{p} 天）",
                                    "\(Int(low))", "\(Int(high))", "\(data.days.count)"))
        }
        let discharge = data.days.map(\.dischargeWh)
        if discharge.contains(where: { $0 > 0 }) {
            let peak = discharge.max() ?? 1
            canvas.line(values: discharge, range: 0...Swift.max(1, peak * 1.1),
                        tint: .systemOrange,
                        caption: tf("每日放电量，峰值 {p} Wh", String(format: "%.1f", peak)))
        }
        if let trend = data.trend {
            canvas.pair(t("每 100 次循环容量变化"),
                        String(format: "%+.2f%%（R² %.2f，%d 个样本）",
                               trend.slopePer100Cycles, trend.rSquared, trend.sampleCount))
            canvas.pair(t("按循环数到 80%"),
                        trend.cyclesToThreshold.map { tf("约 {p} 次循环", "\($0)") } ?? t("数据不足"))
        } else {
            canvas.pair(t("容量衰减斜率"), t("数据不足（至少需要 8 个样本、20 次循环跨度）"))
        }
        canvas.rule()
    }

    private static func drawCalibration(_ data: HealthReportData, on canvas: PDFCanvas) {
        canvas.pageBreak()
        canvas.heading(t("校准记录"))
        canvas.text(calibrationNote(data), style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 8)
        let usable = data.records.filter { $0.calculatedCapacityMAh > 0 }.suffix(5)
        guard !usable.isEmpty else { return }
        for record in usable.reversed() {
            canvas.text(record.endDate.formatted(date: .abbreviated, time: .shortened),
                        style: .init(size: 10, weight: .medium), gapAfter: 1)
            canvas.pair(t("实测容量"), String(format: "%.0f mAh", record.calculatedCapacityMAh))
            canvas.pair(t("健康度"), String(format: "%.1f%%", record.batteryHealthPercentage))
            canvas.pair(t("内阻"), record.internalResistanceMilliohm > 0
                        ? String(format: "%.1f mΩ", record.internalResistanceMilliohm) : "--")
            canvas.pair(t("库仑效率"), record.coulombicEfficiency > 0
                        ? String(format: "%.1f%%", record.coulombicEfficiency * 100) : "--")
            canvas.pair(t("放电区间"), "\(record.startDischargePercentage)% → 20%")
            canvas.text(" ", style: .init(size: 4), gapAfter: 4)
        }
        canvas.rule()
    }

    private static func drawHabits(_ data: HealthReportData, on canvas: PDFCanvas) {
        canvas.heading(t("充电与睡眠"))
        if data.sessions.isEmpty {
            canvas.text(t("没有插电会话记录。"), style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 6)
        } else {
            canvas.text(tf("近 30 天 {p} 次插电会话。", "\(data.sessions.count)"),
                        style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 6)
            for finding in data.habitFindings {
                canvas.text((finding.isPositive ? "✓ " : "! ") + finding.title,
                            style: .init(size: 10, weight: .medium), gapAfter: 1)
                canvas.text(finding.advice, style: .init(size: 9, color: PDFCanvas.Style.secondary), gapAfter: 1)
                for line in finding.evidence {
                    canvas.text("· " + line, style: .init(size: 8, color: PDFCanvas.Style.secondary), gapAfter: 0)
                }
                canvas.text(" ", style: .init(size: 4), gapAfter: 4)
            }
            // The last eight plug-ins, because "how was it charged" is the part
            // of the record a reader can check against their own memory.
            let recent = Array(data.sessions.prefix(8))
            if !recent.isEmpty {
                canvas.text(t("最近插电会话"), style: .init(size: 9, weight: .medium), gapAfter: 3)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "MM/dd HH:mm"
                canvas.table([t("开始"), t("电量区间"), t("插电"), t("充电"), t("满电静置")],
                             rows: recent.map { session in
                                 [formatter.string(from: session.start),
                                  "\(session.startPercentage)–\(session.endPercentage)%",
                                  String(format: "%.1fh", session.pluggedHours),
                                  String(format: "%.1fh", session.chargingSeconds / 3600),
                                  String(format: "%.1fh", session.fullHoldHours)]
                             })
            }
        }
        if let sleep = data.sleepSummary, sleep.count > 0 {
            canvas.pair(t("睡眠次数"), "\(sleep.count)")
            canvas.pair(t("睡眠平均耗电"),
                        sleep.averagePercentPerHour.map { String(format: "%.2f %%/h", $0) } ?? t("数据不足"))
            if let worst = sleep.worst, let rate = worst.percentPerHour {
                canvas.pair(t("最高的一次"), String(format: "%.2f %%/h（%.1f 小时）", rate, worst.hours))
            }
            let sleeps = data.sleeps
            if !sleeps.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "MM/dd HH:mm"
                canvas.table([t("醒来时间"), t("时长"), t("电量"), t("掉电"), t("每小时")],
                             rows: sleeps.map { row in
                                 [formatter.string(from: row.end),
                                  String(format: "%.1fh", row.hours),
                                  "\(row.startPercentage)→\(row.endPercentage)%",
                                  "\(row.lostPercentage) pp",
                                  row.percentPerHour.map { String(format: "%.2f", $0) } ?? "—"]
                             })
            }
        }
        canvas.text(" ", style: .init(size: 4), gapAfter: 8)
        canvas.text(t("本报告用于记录与沟通，不构成硬件故障诊断；数值来自系统上报与本地采样，采样条件逐项标注。"),
                    style: .init(size: 8, color: PDFCanvas.Style.secondary))
    }
}