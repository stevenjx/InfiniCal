//
//  DashboardView.swift
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        PageScaffold(title: Panel.dashboard.title, symbol: Panel.dashboard.symbol) {
            if state.snapshot.isPresent {
                batteryContent
            } else {
                noBatteryContent
            }
        }
    }

    /// A desktop has no battery keys at all, so every figure below reads 0 —
    /// 0 %, 0 mAh, 0 cycles — which looks like a dead pack rather than a
    /// machine that never had one. The power-flow card still has data, so it
    /// stays; the battery cards are replaced by one sentence that says why.
    @ViewBuilder
    private var noBatteryContent: some View {
        Card {
            EmptyState(symbol: "desktopcomputer",
                       title: t("这台 Mac 没有电池"),
                       message: t("仪表板上的电量、健康度与充电控制都依赖电池的 SMC 键，台式机没有这些键。风扇、温度与功耗照常可用。"))
        }
        PowerFlowCard(state: state)
            .frame(height: 224)
    }

    @ViewBuilder
    private var batteryContent: some View {
            PowerFlowCard(state: state)
                .frame(height: 224)
            // No fixed height here: "电池规格" needs more than 172 pt for its
            // six rows, so it overflowed while the two cards with a Spacer
            // stopped at 172 and ended 18 px higher. Letting the tallest card
            // define the row (Spacers make the others match) keeps all three
            // bottom edges on one line.
            HStack(alignment: .top, spacing: 14) {
                batterySpecs.frame(maxWidth: .infinity)
                batteryHealth.frame(maxWidth: .infinity)
                adapterSpecs.frame(maxWidth: .infinity)
            }
            // One row of four equal charts. The right column used to sit next to
            // these, which squeezed each card to ~90 pt and wrapped the titles.
            HStack(alignment: .top, spacing: 14) {
                chartCard(title: t("电池电量"),
                          value: "\(state.snapshot.percentage) %",
                          // The dashed limit line is only readable if the number
                          // it marks is written down somewhere; the axis ticks
                          // alone leave it "somewhere under 100".
                          caption: tf("上限 {p}%", "\(state.chargeVal)"),
                          symbol: "battery.100",
                          color: theme.chartGreen,
                          points: state.history.battery,
                          limit: state.limitMarkerFraction,
                          range: 0...100)
                chartCard(title: t("电池温度"),
                          value: state.snapshot.temperature > 0 ? String(format: "%.0f°C", state.snapshot.temperature) : "--",
                          symbol: "thermometer",
                          color: theme.chartBlue,
                          points: state.history.temperature,
                          limit: nil,
                          range: nil)
                chartCard(title: t("耗电量"),
                          value: PowerFormat.watts(state.energyUseWatts),
                          caption: remainingTimeText,
                          symbol: "bolt.horizontal",
                          color: theme.chartPurple,
                          points: state.history.power,
                          limit: nil,
                          range: nil)
                chartCard(title: t("最大容量"),
                          value: "\(state.snapshot.healthPercent) %",
                          caption: "\(state.snapshot.maxCapacity) / \(state.snapshot.designCapacity) mAh",
                          symbol: "heart",
                          color: theme.chartOrange,
                          points: state.history.capacity,
                          limit: nil,
                          range: nil)
            }

            // Same rule for the bottom row.
            HStack(alignment: .top, spacing: 14) {
                highUsageCard
                calibrationCard
            }
    }

    // MARK: - Specs

    private var batterySpecs: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: t("电池规格"), symbol: "bolt.fill")
                spec(t("电流"), String(format: "%.2f A", abs(state.snapshot.amperage)))
                spec(t("电压"), String(format: "%.2f V", state.snapshot.voltage))
                spec(t("功率"), String(format: "%.1f W", abs(state.snapshot.power)))
                spec(t("系统负载"), String(format: "%.1f W", state.totalPowerWatts),
                     trailing: state.snapshot.systemLoad > 0.05
                         ? String(format: t("1 分钟均值 %.1f W"), state.snapshot.systemLoad)
                         : nil)
                spec(t("低电量模式"), state.snapshot.lowPowerMode ? t("已开启") : t("已关闭"))
                spec(t("电池充电"), "\(state.snapshot.currentCapacity) mAh")
                Spacer(minLength: 0)
            }
        }
    }

    private var batteryHealth: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: t("电池健康"), symbol: "heart.fill")
                spec(t("设计容量"), "\(state.snapshot.designCapacity) mAh")
                spec(t("最大容量"), "\(state.snapshot.maxCapacity) mAh", trailing: "\(state.snapshot.healthPercent) %")
                spec(t("macOS 状态"), state.snapshot.conditionText)
                spec(t("循环次数"), "\(state.snapshot.cycleCount)")
                Spacer(minLength: 0)
            }
        }
    }

    private var adapterSpecs: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: t("电源适配器规格"), symbol: "powerplug.fill")
                if state.snapshot.adapter.isEmpty {
                    Text(t("未连接电源适配器"))
                        .font(Typography.body)
                        .foregroundColor(theme.textSecondary)
                        .padding(.top, 8)
                } else {
                    spec(t("电流"), adapterInput("A", state.snapshot.adapter.current, "%.2f"),
                         trailing: String(format: t("的 %.2f A"), state.snapshot.adapter.maxCurrent))
                    spec(t("电压"), adapterInput("V", state.snapshot.adapter.voltage, "%.2f"),
                         trailing: String(format: t("的 %.0f V"), state.snapshot.adapter.maxVoltage))
                    spec(t("功率"), adapterInput("W", state.snapshot.adapter.power, "%.1f"),
                         trailing: tf("的 {p} W", "\(state.snapshot.adapter.watts)"))
                    spec(t("名称"), state.snapshot.adapter.name)
                    spec(t("制造商"), state.snapshot.adapter.manufacturer)
                    spec(t("序列号"), state.snapshot.adapter.serial)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A measured adapter value, or an em dash when the platform reports none.
    private func adapterInput(_ unit: String, _ value: Double, _ format: String) -> String {
        guard state.snapshot.adapter.hasMeasuredInput else { return "—" }
        return String(format: "\(format) \(unit)", value)
    }

    /// One spec row: `body` for both sides of the pair, so a card of six rows
    /// reads as a table instead of six whispers.
    private func spec(_ title: String, _ value: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(Typography.body)
                .foregroundColor(theme.textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(Typography.body.monospacedDigit())
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .numericTextTransition()
            if let trailing {
                Text(trailing)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundColor(theme.textTertiary)
            }
        }
    }

    // MARK: - Charts

    private func chartCard(title: String, value: String, caption: String? = nil,
                           symbol: String, color: Color,
                           points: [HistoryPoint], limit: Double?, range: ClosedRange<Double>?) -> some View {
        Card {
            MiniChart(title: title, valueText: value, caption: caption, symbol: symbol, color: color,
                      points: points, limitFraction: limit, range: range)
        }
        .frame(maxWidth: .infinity)
    }

    /// Remaining runtime = stored energy ÷ current draw.
    ///
    /// Only meaningful while the pack is the power source. On AC the same number
    /// would be the time until the *battery* is drained by a charger that is
    /// actually filling it, so we show the charge side instead: minutes to full
    /// when the driver reports one, otherwise the fact that it is charging.
    private var remainingTimeText: String {
        if state.snapshot.isPluggedIn {
            if let minutes = state.snapshot.timeToFull, minutes > 0, minutes < 24 * 60 {
                return tf("充满约 {p} 小时 {p} 分", "\(minutes / 60)", "\(minutes % 60)")
            }
            return state.snapshot.isCharging ? t("充电中") : t("已接电源")
        }
        guard let hours = state.snapshot.remainingHours(atPower: state.energyUseWatts) else {
            return "—"
        }
        // Round to the nearest minute; a seconds-precision estimate would imply
        // accuracy the measurement does not have.
        let totalMinutes = max(1, Int((hours * 60).rounded()))
        return tf("剩余 {p} 小时 {p} 分", "\(totalMinutes / 60)", "\(totalMinutes % 60)")
    }

    /// Second line under a process name: what it costs and what closing it buys.
    /// The minute figure is omitted on AC, where the saving is wall power rather
    /// than battery life.
    private func gainText(_ app: HighUsageApp) -> String {
        let watts = String(format: "%.1f", app.estimatedWatts)
        guard app.estimatedGainMinutes > 0 else { return tf("约 {p} W", watts) }
        return tf("约 {p} W · 关闭可多 {p} 分钟", watts, "\(app.estimatedGainMinutes)")
    }

    // MARK: - Bottom row cards

    private var highUsageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: t("高功耗的应用程序"))
                if state.highUsageApps.isEmpty {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(theme.innerControl)
                            .frame(width: 26, height: 26)
                            .overlay(Image(systemName: "app.dashed").font(Glyph.row).foregroundColor(theme.textTertiary))
                        Text(t("暂无"))
                            .font(Typography.body)
                            .foregroundColor(theme.textSecondary)
                    }
                } else {
                    ForEach(state.highUsageApps.prefix(2)) { app in
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(Typography.body)
                                    .foregroundColor(theme.textPrimary)
                                    .lineLimit(1)
                                if app.estimatedWatts > 0 {
                                    Text(gainText(app))
                                        .font(Typography.micro)
                                        .foregroundColor(theme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(String(format: "%.1f%%", app.energyImpact))
                                .font(Typography.caption.monospacedDigit())
                                .foregroundColor(theme.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var calibrationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: t("上一次校准")) {
                    Text(state.lastCalibrationDate.map { Self.dateFormatter.string(from: $0) } ?? "-")
                        .font(Typography.caption)
                        .foregroundColor(theme.textPrimary)
                }
                Button {
                    state.requestCalibrationStart()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.calibration == nil ? "play.fill" : "stop.fill")
                            .font(Glyph.inline)
                        Text(state.calibration == nil ? t("开始校准") : t("停止校准"))
                            .font(Typography.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(Glyph.inline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
                    .foregroundColor(theme.textPrimary)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}

private struct PowerFlowCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var flowTicker = AppState.shared.flowTicker

    var body: some View {
        // No chip row above the diagram: every number it printed is now either
        // the figure on the left or a legend row on the right, and the row was
        // what forced the diagram into 176 pt of a 196 pt card.
        Card {
            PowerFlowView(model: state.flowModel, ticker: flowTicker)
        }
    }
}

