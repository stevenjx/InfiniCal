//
//  HistoryPanel.swift
//  Daily battery history: energy in, energy out, temperature, time on AC.
//

import SwiftUI
import AppKit

struct HistoryView: View {

    @ObservedObject private var history = DailyHistory.shared
    @ObservedObject private var alerts = AnomalyAlerts.shared
    @ObservedObject private var sessions = ChargeSessionStore.shared
    @ObservedObject private var calibration = CalibrationEngine.shared
    @EnvironmentObject private var state: AppState
    @StateObject private var range = UIValue<Int>(7)
    /// The recovery card is dismissed by the user, not by the next redraw:
    /// `CalibrationStore.readStatus` is a static, so acknowledging it does not
    /// publish and the card would otherwise stay until a relaunch.
    @StateObject private var recoveryDismissed = UIFlag(false)
    @StateObject private var machines = ImportedMachineStore.shared
    @State private var migrationMessage: String?
    private var theme: Theme { Theme.current }

    private var stats: [DailyStat] { history.series(days: range.value) }
    private var isEmpty: Bool { stats.allSatisfy { $0.isEmpty } }
    private var advice: AdviceReport {
        AdviceProvider.report(days: history.days, records: calibration.records,
                              chargeLimit: state.chargeVal,
                              storageStartedAt: state.storageStartedAt)
    }

    var body: some View {
        PageScaffold(title: Panel.history.title,
                     symbol: Panel.history.symbol,
                     help: t("每天充入与放出的电量、温度区间和接电时长。用于观察长期使用习惯，不参与健康度计算。"),
                     toolbar: { rangeToolbar }) {
            storeIssueCard
            AdviceCard(report: advice)
            alertCenter
            chargeHabits

            if isEmpty {
                emptyState
            } else {
                summary
                chartCard
                listCard
            }
            healthTrends
            migrationCard

            Text(t("按自然日聚合，数据来自本机电池的电压 × 电流积分；App 未运行时不计入。"))
                .font(Typography.caption)
                .foregroundColor(theme.textTertiary)
        }
    }

    // MARK: - Header

    /// The startup recovery notice. It is a card rather than a banner because
    /// the user has to be able to read the quarantine path and copy it.
    ///
    /// Two mysteries this card exists to prevent: "my history is empty" (the
    /// file did not decode) and "my history came back from yesterday" (the
    /// backup was used). Both are stated plainly, and neither is thrown away
    /// silently.
    @ViewBuilder
    private var storeIssueCard: some View {
        let daily = history.readStatus
        let calibration = recoveryDismissed.value ? .clean : CalibrationStore.readStatus
        if !recoveryDismissed.value, daily.needsAttention || calibration.needsAttention {
            Card {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    CardHeader(title: t("本地数据已自动恢复"),
                               symbol: "externaldrive.badge.exclamationmark",
                               tint: theme.chartOrange,
                               subtitle: t("读取失败的数据文件已原样保留，没有被覆盖。"))
                    if daily.needsAttention {
                        storeIssueLine(t("每日历史"), daily)
                    }
                    if calibration.needsAttention {
                        storeIssueLine(t("校准记录"), calibration)
                    }
                    HStack(spacing: 8) {
                        SmallActionButton(title: t("我已了解"), symbol: "checkmark") {
                            recoveryDismissed.value = true
                            history.acknowledgeReadIssue()
                            CalibrationStore.acknowledgeReadIssue()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func storeIssueLine(_ name: String, _ status: StoreReadStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(storeIssueSummary(name, status))
                .font(Typography.caption)
                .foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = status.quarantinePath {
                Text(path)
                    .font(Typography.micro.monospaced())
                    .foregroundColor(theme.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func storeIssueSummary(_ name: String, _ status: StoreReadStatus) -> String {
        switch status {
        case .clean:
            return ""
        case .recoveredFromBackup:
            return tf("{p}读取失败，已从备份恢复；损坏的文件保留在旁边。", name)
        case .startedEmpty:
            return tf("{p}与备份都无法读取，本次从空白开始；原来的文件保留在旁边，可手动检查。", name)
        }
    }

    /// Range chips and the clear action: the page's toolbar, right of the title.
    private var rangeToolbar: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xs + Spacing.xxs) {
                ChipButton(title: t("7 天"), selected: range.value == 7) { range.value = 7 }
                ChipButton(title: t("30 天"), selected: range.value == 30) { range.value = 30 }
                ChipButton(title: t("90 天"), selected: range.value == 90) { range.value = 90 }
            }
            Button(t("生成 PDF 报告")) { exportPDF() }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundColor(theme.accent)
            if !history.days.isEmpty {
                Button(t("清除")) { confirmClear() }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
        }
    }

    // MARK: - Migration

    /// Export / import for moving history to another Mac, plus the list of
    /// machines already imported. The list is the "compare two Macs" feature in
    /// its honest form: two health numbers side by side, not overlaid curves
    /// whose x-axis (calendar time) means different things on different machines.
    private var migrationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: t("迁移与多机对比"),
                           subtitle: t("导出的文件只包含电量、容量、会话与设置，不含序列号、用户名或路径。"))
                HStack(spacing: Spacing.s) {
                    SmallActionButton(title: t("导出迁移包"), symbol: "square.and.arrow.up") { exportArchive() }
                    SmallActionButton(title: t("导入迁移包"), symbol: "square.and.arrow.down") { importArchive() }
                    Spacer(minLength: 0)
                }
                if let migrationMessage {
                    Text(migrationMessage)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !machines.machines.isEmpty {
                    Divider().background(theme.divider)
                    ForEach(machines.machines) { machine in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            Image(systemName: "laptopcomputer")
                                .font(Glyph.inline)
                                .foregroundColor(theme.textTertiary)
                            Text(machine.model).font(Typography.caption).foregroundColor(theme.textPrimary)
                            Spacer(minLength: Spacing.s)
                            Text(tf("健康度 {p}% · {p} 次循环", "\(machine.healthPercent)", "\(machine.cycleCount)"))
                                .font(Typography.caption.monospacedDigit())
                                .foregroundColor(theme.textSecondary)
                            Text(machine.exportedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(Typography.micro)
                                .foregroundColor(theme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "InfiniCal-\(stamp.string(from: Date())).infinicalarchive"
        panel.message = t("导出迁移包")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Migration.encode(state.makeArchive())
            try data.write(to: url, options: .atomic)
            migrationMessage = tf("已导出迁移包（{p} KB）", "\(max(1, data.count / 1024))")
        } catch {
            migrationMessage = error.localizedDescription
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = t("选择 .infinicalarchive 文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try state.importArchive(data)
            migrationMessage = result.summary
        } catch let error as MigrationError {
            migrationMessage = error.message
        } catch {
            migrationMessage = error.localizedDescription
        }
    }

    // MARK: - Charge habits

    /// A plug-in session is the unit `DailyStat` cannot see: one night parked at
    /// 100 % and one quick top-up to 80 % land in the same daily row. This card
    /// is where that difference becomes visible and actionable.
    private var chargeHabits: some View {
        let report = ChargeHabitAnalyzer.analyze(sessions.sessions)
        return Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: t("充电习惯"),
                           subtitle: report.observedDays < ChargeHabitAnalyzer.Report.minimumDays
                               ? tf("还需要 {p} 天数据才能给出结论", "\(max(0, ChargeHabitAnalyzer.Report.minimumDays - report.observedDays))")
                               : tf("近 30 天 {p} 次插电会话", "\(report.sessions.count)"))
                if report.findings.isEmpty {
                    Text(report.observedDays < ChargeHabitAnalyzer.Report.minimumDays
                         ? t("会话记录还不够：接上电源使用几天后，这里会按满电静置、深充深放、高温充电和浅充浅放给出结论。")
                         : t("最近 30 天的充电方式没有需要调整的模式。"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(report.findings) { finding in
                        habitRow(finding)
                    }
                }
                if !report.sessions.isEmpty {
                    Divider().background(theme.divider)
                    sessionTable(report.sessions)
                }
                if let window = UsageProfile.bestChargingWindow(
                    profile: UsageProfile.build(from: history.days)) {
                    Divider().background(theme.divider)
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(Glyph.inline)
                            .foregroundColor(theme.info)
                        Text(tf("一天里放电最慢的是 {p}:00–{p}:00（约 {p} W）；补电安排在这里最省循环。",
                                "\(window.startHour)", "\((window.startHour + 2) % 24)",
                                String(format: "%.1f", window.watts)))
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func habitRow(_ finding: ChargeHabitFinding) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Image(systemName: finding.isPositive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Glyph.inline)
                    .foregroundColor(finding.isPositive ? theme.success : theme.warning)
                Text(finding.title).font(Typography.label)
                Spacer(minLength: 0)
            }
            Text(finding.advice)
                .font(Typography.caption)
                .foregroundColor(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(finding.evidence, id: \.self) { line in
                Text("· " + line)
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
    }

    /// Newest first, eight rows. More than that is a log, not a summary.
    private func sessionTable(_ sessions: [ChargeSession]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(t("开始"))
                    .frame(width: 116, alignment: .leading)
                Text(t("电量区间"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("插电"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("充电"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("满电静置"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(Typography.label)
            .foregroundColor(theme.textTertiary)
            .frame(height: 24)
            ForEach(Array(sessions.prefix(8))) { session in
                HStack(spacing: 0) {
                    Text(Self.sessionFormatter.string(from: session.start))
                        .frame(width: 116, alignment: .leading)
                        .foregroundColor(theme.textPrimary)
                    Text("\(session.startPercentage)–\(session.endPercentage)%")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(hours(session.pluggedHours))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(hours(session.chargingSeconds / 3600))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(session.fullHoldSeconds > 0 ? hours(session.fullHoldHours) : "—")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Typography.caption.monospacedDigit())
                .foregroundColor(theme.textSecondary)
                .frame(height: 24)
            }
        }
    }

    private func hours(_ value: Double) -> String {
        value >= 1 ? String(format: "%.1f h", value) : String(format: "%.0f min", value * 60)
    }

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private var alertCenter: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.s) {
                CardHeader(title: t("异常告警"),
                           subtitle: t("仅在 App 运行并持续观测时判断；提醒是异常证据，不是硬件故障诊断。"))
                if alerts.events.isEmpty { Text(t("暂无异常记录")).font(Typography.caption) }
                ForEach(alerts.events) { event in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.s) {
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
        return Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: t("电池健康趋势"),
                           subtitle: tf("有效日样本 {p} · 有效校准 {p} · 未评估或低质量 {p}",
                                        "\(window.days.count)", "\(window.records.count)",
                                        "\(window.excludedRecords)"))
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
        HStack(spacing: Spacing.m) {
            summaryCard(t("充入"), energy(totalCharge), "arrow.down.to.line", theme.chartGreen)
            summaryCard(t("放出"), energy(totalDischarge), "arrow.up.to.line", theme.chartOrange)
            summaryCard(t("平均温度"), String(format: "%.1f °C", averageTemperature), "thermometer.medium", theme.chartBlue)
            summaryCard(t("接电时长"), String(format: t("%.1f 小时"), totalPluggedHours), "powerplug", theme.chartPurple)
        }
    }

    /// Three lines in every tile: label, figure, period. The label was `caption`
    /// (11 regular) and the figure `title` (15) — the same sizes the page used
    /// for body copy, so a stat tile did not read as a stat.
    private func summaryCard(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        Card(padding: .compact) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: symbol)
                        .font(Glyph.inline)
                        .foregroundColor(tint)
                    Text(title)
                        .font(Typography.label)
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(value)
                    .font(Typography.figure)
                    .foregroundColor(theme.textPrimary)
                Text(tf("近 {p} 天", "\(range.value)"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chart

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: t("每日充放电")) {
                    HStack(spacing: Spacing.m) {
                        legend(t("充入"), theme.chartGreen)
                        legend(t("放出"), theme.chartOrange)
                        Text("Wh")
                            .font(Typography.micro)
                            .foregroundColor(theme.textTertiary)
                    }
                }

                // The bars had no scale at all: a 29 Wh day and a 3 Wh day were
                // the same shape, only taller or shorter, with no number to
                // anchor either. Three ticks and a grid, same as `MiniChart`.
                HStack(alignment: .top, spacing: Spacing.s) {
                    VStack(spacing: Spacing.xs) {
                        DailyBarChart(stats: stats, axisMax: barAxisMax)
                            .frame(height: 120)
                        dayAxis
                    }
                    barTicks
                        .frame(width: 40, height: 120)
                }
            }
        }
    }

    /// Rounded up to 1 / 1.5 / 2 / 2.5 / 3 / 4 / 5 / 6 / 8 / 10 × 10ⁿ so the
    /// top tick is a number a person would write, and the tallest bar still
    /// reaches most of the way up.
    private var barAxisMax: Double {
        let peak = stats.map { max($0.chargeWh, $0.dischargeWh) }.max() ?? 0
        guard peak > 0 else { return 1 }
        let exponent = floor(log10(peak))
        let base = pow(10, exponent)
        let scaled = peak / base
        let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let step = steps.first { scaled <= $0 + 1e-9 } ?? 10
        return step * base
    }

    private var barTicks: some View {
        let max = barAxisMax
        return VStack(alignment: .trailing, spacing: 0) {
            tick(max).frame(maxHeight: .infinity, alignment: .top)
            tick(max / 2).frame(maxHeight: .infinity, alignment: .center)
            tick(0).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func tick(_ value: Double) -> some View {
        Text(String(format: "%.0f", value))
            .font(Typography.micro)
            .foregroundColor(theme.textTertiary)
            .fixedSize()
    }

    /// First, middle, and today. The last bar is always today — `series(days:)`
    /// ends on the current day — so the right-hand label says so instead of
    /// repeating a date the reader has to compare against the clock.
    private var dayAxis: some View {
        HStack(spacing: 0) {
            Text(Self.dayLabel(stats.first?.day))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.dayLabel(middleDay))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(t("今天"))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Typography.micro)
        .foregroundColor(theme.textTertiary)
        .lineLimit(1)
    }

    private var middleDay: Date? {
        let index = stats.count / 2
        return stats.indices.contains(index) ? stats[index].day : nil
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
        }
    }

    // MARK: - List

    private let dateColumnWidth: CGFloat = 88

    private var listCard: some View {
        Card(kind: .list) {
            VStack(spacing: 0) {
                tableLine(t("日期"),
                          [t("充入"), t("放出"), t("温度"), t("电量区间"), t("接电")],
                          header: true)
                Divider().background(theme.divider)
                ForEach(Array(stats.reversed().enumerated()), id: \.element.id) { index, stat in
                    tableLine(Self.dayLabel(stat.day),
                              [stat.isEmpty ? "—" : energy(stat.chargeWh),
                               stat.isEmpty ? "—" : energy(stat.dischargeWh),
                               stat.isEmpty ? "—" : String(format: "%.0f °C", stat.averageTemperature),
                               stat.isEmpty ? "—" : "\(stat.minPercentage)–\(stat.maxPercentage)%",
                               stat.isEmpty ? "—" : String(format: "%.1f h", stat.pluggedHours)],
                              header: false,
                              striped: index % 2 == 1,
                              dimmed: stat.isEmpty)
                }
            }
        }
    }

    /// One row shape for the header and the body, so the two cannot drift apart.
    /// 28 pt rows with a 3 % band on every other line: the divider-per-row this
    /// replaces drew a rule under every line and still left the eye nothing to
    /// follow across six columns.
    ///
    /// Column widths stay `maxWidth: .infinity` rather than measured: the plan
    /// said the numbers were not right-aligned, but the old header and rows
    /// measured 0–2 px apart on the right edge, so equal-share columns already
    /// worked and a width-measuring pass would have been machinery for nothing.
    private func tableLine(_ date: String,
                           _ cells: [String],
                           header: Bool,
                           striped: Bool = false,
                           dimmed: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(date)
                .frame(width: dateColumnWidth, alignment: .leading)
                .foregroundColor(header ? theme.textTertiary : theme.textPrimary)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundColor(header ? theme.textTertiary : theme.textSecondary)
            }
        }
        .font(header ? Typography.label : Typography.caption.monospacedDigit())
        .padding(.horizontal, CardPadding.regular)
        .frame(height: 28)
        .background(striped ? theme.textPrimary.opacity(0.03) : Color.clear)
        .opacity(dimmed ? 0.45 : 1)
    }

    private var emptyState: some View {
        Card {
            EmptyState(symbol: "chart.bar.xaxis",
                       title: t("还没有历史数据"),
                       message: t("InfiniCal 每 2 秒采样一次电池功率，按天累加。保持运行一天后，这里会出现第一根柱子。"))
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

    /// One click, one file. The panel opens before the work so a slow disk
    /// shows the system's own progress rather than a frozen window.
    private func exportPDF() {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "InfiniCal-Report-\(stamp.string(from: Date())).pdf"
        panel.message = t("导出电池体检报告")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = HealthReportCollector.collect()
        guard let pdf = HealthReport.makePDF(data) else {
            state.lastMessage = t("报告生成失败")
            return
        }
        do {
            try pdf.write(to: url, options: .atomic)
            state.lastMessage = tf("报告已导出（{p} KB）", "\(max(1, pdf.count / 1024))")
        } catch {
            state.lastMessage = error.localizedDescription
        }
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
    /// Shared with the tick column, so a bar's height and the number beside it
    /// mean the same thing.
    let axisMax: Double
    private var theme: Theme { Theme.current }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    gridLine
                    Spacer(minLength: 0)
                    gridLine
                    Spacer(minLength: 0)
                    gridLine
                }
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
    }

    private var gridLine: some View {
        Rectangle().fill(theme.divider).frame(height: 1)
    }

    private func bar(value: Double, height: CGFloat, color: Color) -> some View {
        let fraction = min(1, max(0, value / max(axisMax, 1)))
        return Capsule()
            .fill(value > 0 ? color : theme.divider.opacity(0.5))
            .frame(maxWidth: 14)
            .frame(height: value > 0 ? max(1.5, height * CGFloat(fraction)) : 1.5)
    }
}
