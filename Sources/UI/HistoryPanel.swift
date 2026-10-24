//
//  HistoryPanel.swift
//  Daily battery history: energy in, energy out, temperature, time on AC.
//

import SwiftUI
import AppKit

struct HistoryView: View {

    @ObservedObject private var history = DailyHistory.shared
    @StateObject private var range = UIValue<Int>(7)
    private var theme: Theme { Theme.current }

    private var stats: [DailyStat] { history.series(days: range.value) }
    private var isEmpty: Bool { stats.allSatisfy { $0.isEmpty } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header

                if isEmpty {
                    emptyState
                } else {
                    summary
                    chartCard
                    listCard
                }

                Text(t("按自然日聚合，数据来自本机电池的电压 × 电流积分；App 未运行时不计入。"))
                    .font(.system(size: 10))
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
                .font(.system(size: 13))
                .foregroundColor(theme.textPrimary)
            HelpDot(text: t("每天充入与放出的电量、温度区间和接电时长。用于观察长期使用习惯，不参与健康度计算。"))
            Spacer()
            HStack(spacing: 6) {
                ChipButton(title: t("7 天"), selected: range.value == 7) { range.value = 7 }
                ChipButton(title: t("30 天"), selected: range.value == 30) { range.value = 30 }
            }
            if !history.days.isEmpty {
                Button(t("清除")) { confirmClear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textTertiary)
            }
        }
        .frame(height: 34)
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
                        .font(.system(size: 10))
                        .foregroundColor(tint)
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                Text(tf("近 {p} 天", "\(range.value)"))
                    .font(.system(size: 9))
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    legend(t("充入"), theme.chartGreen)
                    legend(t("放出"), theme.chartOrange)
                    Spacer()
                    Text(peakText)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                }
                DailyBarChart(stats: stats)
                    .frame(height: 132)
                HStack {
                    Text(Self.dayLabel(stats.first?.day))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                    Spacer()
                    Text(Self.dayLabel(stats.last?.day))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10))
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
                .font(.system(size: 10))
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
                    .font(.system(size: 11).monospacedDigit())
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
                    .font(.system(size: 30))
                    .foregroundColor(theme.textTertiary)
                Text(t("还没有历史数据"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Text(t("InfiniCal 每 2 秒采样一次电池功率，按天累加。保持运行一天后，这里会出现第一根柱子。"))
                    .font(.system(size: 11))
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
