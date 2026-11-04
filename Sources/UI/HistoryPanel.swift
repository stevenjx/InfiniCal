//
//  HistoryPanel.swift
//  Daily battery history: energy in, energy out, temperature, time on AC.
//

import SwiftUI
import AppKit

struct HistoryView: View {

    @ObservedObject private var history = DailyHistory.shared
    @ObservedObject private var alerts = AnomalyAlerts.shared
    @ObservedObject private var calibration = CalibrationEngine.shared
    @EnvironmentObject private var state: AppState
    @StateObject private var range = UIValue<Int>(7)
    private var theme: Theme { Theme.current }

    private var stats: [DailyStat] { history.series(days: range.value) }
    private var isEmpty: Bool { stats.allSatisfy { $0.isEmpty } }
    private var advice: AdviceReport {
        AdviceProvider.report(days: history.days, records: calibration.records,
                              chargeLimit: state.chargeVal)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                AdviceCard(report: advice)
                alertCenter

                if isEmpty {
                    emptyState
                } else {
                    summary
                    chartCard
                    listCard
                }
                healthTrends

                Text(t("按自然日聚合，数据来自本机电池的电压 × 电流积分；App 未运行时不计入。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                    .padding(.top, 2)
            }
            .padding(22)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "chart.bar.xaxis")
            Text(t("电池历史"))
                .font(Typography.title)
                .foregroundColor(theme.textPrimary)
            HelpDot(text: t("每天充入与放出的电量、温度区间和接电时长。用于观察长期使用习惯，不参与健康度计算。"))
            Spacer()
            HStack(spacing: 6) {
                ChipButton(title: t("7 天"), selected: range.value == 7) { range.value = 7 }
                ChipButton(title: t("30 天"), selected: range.value == 30) { range.value = 30 }
                ChipButton(title: t("90 天"), selected: range.value == 90) { range.value = 90 }
            }
            if !history.days.isEmpty {
                Button(t("清除")) { confirmClear() }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
        }
        .frame(height: 34)
    }

    private var alertCenter: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("异常告警")).font(Typography.headline)
                Text(t("仅在 App 运行并持续观测时判断；提醒是异常证据，不是硬件故障诊断。"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                if alerts.events.isEmpty { Text(t("暂无异常记录")).font(Typography.caption) }
                ForEach(alerts.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t(event.title))
                            Spacer()
                            Text(event.date, style: .time)
                            Button(t("忽略本次")) { alerts.ignore(event.id) }
                            Button(t("关闭此类")) { alerts.setDisabled(event.id, true) }
                        }
                        Text(event.detail).textSelection(.enabled)
                    }.font(Typography.caption)
                }
                ForEach(AnomalyAlerts.rules.filter { alerts.disabled.contains($0.id) }, id: \.id) { rule in
                    Button(t("重新启用") + " · " + t(rule.title)) { alerts.setDisabled(rule.id, false) }
                        .font(Typography.caption)
                }
            }
        }
    }

    private var healthTrends: some View {
        let window = HealthWindow(days: history.days, records: calibration.records, count: range.value)
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("电池健康趋势")).font(Typography.headline)
                Text(tf("有效日样本 {p} · 有效校准 {p} · 未评估或低质量 {p}",
                        "\(window.days.count)", "\(window.records.count)", "\(window.excludedRecords)"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                trendLine(t("系统满充容量变化"), window.reportedDelta, "mAh")
                trendLine(t("校准实测容量变化"), window.capacityDelta, "mAh")
                trendLine(t("DCIR 变化"), window.resistanceDelta, "mΩ")
                datedCurve(t("系统满充容量"), points: window.days.compactMap { day in
                    day.reportedCapacityMAh.map { (day.day, Double($0)) }
                }, gapDays: 2, unit: "mAh")
                datedCurve(t("校准实测容量"), points: window.comparableRecords.map { ($0.endDate, $0.calculatedCapacityMAh) }, gapDays: 30, unit: "mAh")
                datedCurve("DCIR", points: window.comparableRecords.map { ($0.endDate, $0.internalResistanceMilliohm) }, gapDays: 30, unit: "mΩ")
                rateLine(t("实测容量拟合变化率"), window.capacityRate, unit: "mAh/30d")
                rateLine(t("DCIR 拟合变化率"), window.resistanceRate, unit: "mΩ/30d")
                Text(tf("条件匹配 {p}/{p}：同机型、后端、负载模式和目标；温差≤3°C，功率差≤20%，起始电量差≤2%。旧记录条件未知，不参与匹配。",
                        "\(window.comparableRecords.count)", "\(window.records.count)"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                Text(t("拟合至少需要4个不同日期样本、跨度14天；正值也可能是容量回升。R²仅表示拟合程度，不是置信概率。曲线不插值补样本，长间隔断线。"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                trendLine(t("循环次数变化"), window.cycleDelta, "")
                HStack {
                    Text(t("已观测高温时长（≥40°C）"))
                    Spacer()
                    Text(window.highTemperatureHours.map { String(format: "%.2f h", $0) } ?? "--")
                }.font(Typography.caption)
                if window.records.count >= 2 {
                    ForEach(Array(window.records.suffix(5))) { record in
                        HStack {
                            Text(record.endDate, style: .date)
                            Spacer()
                            Text(String(format: "%.0f mAh · %.1f%% · %.1f mΩ", record.calculatedCapacityMAh,
                                        record.batteryHealthPercentage, record.internalResistanceMilliohm))
                            Text(record.quality.map { t($0.label) } ?? "--")
                        }.font(Typography.caption).foregroundColor(theme.textSecondary)
                    }
                }
                Text(t("变化为窗口内首末有效样本之差，不是衰减速度；温度、负载和测量协议不同会影响比较。少于两个样本显示 --。"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                Text(t("高温时长仅统计 App 运行且温度有效的区间；旧记录缺失值不补零。系统容量与校准实测值不混合。"))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
            }
        }
    }

    private func rateLine(_ label: String, _ rate: HealthRegression?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            trendLine(label, rate?.changePer30Days, unit)
            if let rate {
                Text(String(format: "n=%d · %.0f d · R²=%.2f", rate.sampleCount, rate.spanDays, rate.rSquared))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
            }
        }
    }

    private func datedCurve(_ title: String, points: [(Date, Double)], gapDays: Double, unit: String) -> some View {
        let valid = points.filter { $0.1.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        return VStack(alignment: .leading, spacing: 4) {
            Text(t(title) + " · " + unit).font(Typography.caption)
            if let first = valid.first, let last = valid.last {
                let low = valid.map { $0.1 }.min() ?? first.1
                let high = valid.map { $0.1 }.max() ?? first.1
                Text(String(format: "%.1f–%.1f %@ · n=%d", low, high, unit, valid.count))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
                GeometryReader { geometry in
                    let duration = max(1, last.0.timeIntervalSince(first.0))
                    let span = max(1, high - low)
                    let locations = valid.map { point in
                        CGPoint(x: 4 + (geometry.size.width - 8) * point.0.timeIntervalSince(first.0) / duration,
                                y: 4 + (geometry.size.height - 8) * (1 - (point.1 - low) / span))
                    }
                    Path { path in
                        for index in locations.indices {
                            if index == 0 || valid[index].0.timeIntervalSince(valid[index - 1].0) > gapDays * 86400 {
                                path.move(to: locations[index])
                            } else { path.addLine(to: locations[index]) }
                        }
                    }.stroke(theme.chartBlue, lineWidth: 1.5)
                    ForEach(locations.indices, id: \.self) { index in
                        Circle().fill(theme.chartBlue).frame(width: 4, height: 4).position(locations[index])
                            .help(valid[index].0.formatted() + " · " + String(format: "%.1f %@", valid[index].1, unit))
                    }
                }.frame(height: 70)
                HStack {
                    Text(first.0, style: .date)
                    Spacer()
                    Text(last.0, style: .date)
                }.font(Typography.caption).foregroundColor(theme.textSecondary)
            } else { Text("--").font(Typography.body) }
        }
    }

    private func trendLine(_ label: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.map { String(format: "%+.1f %@", $0, unit) } ?? "--")
        }.font(Typography.body).foregroundColor(theme.textPrimary)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 10) {
            summaryCard(t("充入"), energy(totalCharge), "arrow.down.to.line", theme.chartGreen)
            summaryCard(t("放出"), energy(totalDischarge), "arrow.up.to.line", theme.chartOrange)
            summaryCard(t("平均温度"), String(format: "%.1f °C", averageTemperature), "thermometer.medium", theme.chartBlue)
            summaryCard(t("接电时长"), String(format: t("%.1f 小时"), totalPluggedHours), "powerplug", theme.chartPurple)
        }
    }

    private func summaryCard(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(Glyph.inline)
                        .foregroundColor(tint)
                    Text(title)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(Typography.title.monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                Text(tf("近 {p} 天", "\(range.value)"))
                    .font(Typography.micro)
                    .foregroundColor(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chart

    private var chartCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(t("每日充放电"))
                        .font(Typography.headline)
                        .foregroundColor(theme.textPrimary)
                    legend(t("充入"), theme.chartGreen)
                    legend(t("放出"), theme.chartOrange)
                    Spacer()
                    Text(peakText)
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                }
                DailyBarChart(stats: stats)
                    .frame(height: 132)
                HStack {
                    Text(Self.dayLabel(stats.first?.day))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                    Spacer()
                    Text(Self.dayLabel(stats.last?.day))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
        }
    }

    private var peakText: String {
        let peak = stats.map { max($0.chargeWh, $0.dischargeWh) }.max() ?? 0
        return peak > 0 ? tf("峰值 {p}", energy(peak)) : ""
    }

    // MARK: - List

    private var listCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(t("日期")).frame(width: 96, alignment: .leading)
                    Text(t("充入")).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(t("放出")).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(t("温度")).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(t("电量区间")).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(t("接电")).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Typography.caption)
                .foregroundColor(theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().background(theme.divider)

                ForEach(stats.reversed()) { stat in
                    HStack(spacing: 0) {
                        Text(Self.dayLabel(stat.day))
                            .frame(width: 96, alignment: .leading)
                            .foregroundColor(theme.textPrimary)
                        Text(stat.isEmpty ? "—" : energy(stat.chargeWh))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(theme.textPrimary)
                        Text(stat.isEmpty ? "—" : energy(stat.dischargeWh))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(theme.textPrimary)
                        Text(stat.isEmpty ? "—" : String(format: "%.0f °C", stat.averageTemperature))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(theme.textSecondary)
                        Text(stat.isEmpty ? "—" : "\(stat.minPercentage)–\(stat.maxPercentage)%")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(theme.textSecondary)
                        Text(stat.isEmpty ? "—" : String(format: "%.1f h", stat.pluggedHours))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(theme.textSecondary)
                    }
                    .font(Typography.caption.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .opacity(stat.isEmpty ? 0.45 : 1)

                    Divider().background(theme.divider)
                }
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(Glyph.hero)
                    .foregroundColor(theme.textTertiary)
                Text(t("还没有历史数据"))
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Text(t("InfiniCal 每 2 秒采样一次电池功率，按天累加。保持运行一天后，这里会出现第一根柱子。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Derived

    private var totalCharge: Double { stats.reduce(0) { $0 + $1.chargeWh } }
    private var totalDischarge: Double { stats.reduce(0) { $0 + $1.dischargeWh } }
    private var totalPluggedHours: Double { stats.reduce(0) { $0 + $1.pluggedHours } }

    private var averageTemperature: Double {
        let sum = stats.reduce(0) { $0 + $1.temperatureSum }
        let count = stats.reduce(0) { $0 + $1.temperatureSamples }
        return count > 0 ? sum / Double(count) : 0
    }

    private func energy(_ wh: Double) -> String {
        wh >= 1000 ? String(format: "%.2f kWh", wh / 1000) : String(format: "%.1f Wh", wh)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = t("清除全部历史？")
        alert.informativeText = t("按天聚合的电量与温度记录会被删除，此操作不可撤销。")
        alert.addButton(withTitle: t("清除"))
        alert.addButton(withTitle: t("取消"))
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    private static func dayLabel(_ day: Date?) -> String {
        guard let day else { return "—" }
        return dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd EEE"
        return formatter
    }()
}

// MARK: - Bars

private struct DailyBarChart: View {
    let stats: [DailyStat]
    private var theme: Theme { Theme.current }

    private var peak: Double {
        max(1, stats.map { max($0.chargeWh, $0.dischargeWh) }.max() ?? 1)
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(stats) { stat in
                    HStack(alignment: .bottom, spacing: 1.5) {
                        bar(value: stat.chargeWh, height: height, color: theme.chartGreen)
                        bar(value: stat.dischargeWh, height: height, color: theme.chartOrange)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private func bar(value: Double, height: CGFloat, color: Color) -> some View {
        let fraction = min(1, max(0, value / peak))
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(value > 0 ? color : theme.divider.opacity(0.5))
            .frame(maxWidth: 14)
            .frame(height: value > 0 ? max(1.5, height * CGFloat(fraction)) : 1.5)
    }
}
