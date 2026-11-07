//
//  PanelsBattery.swift  (睡眠与能源)
//

import SwiftUI

struct SleepEnergyView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var alerts = AnomalyAlerts.shared
    @ObservedObject private var sleepSessions = SleepSessionStore.shared
    private var theme: Theme { Theme.current }
    @StateObject private var advanced = UIFlag()

    private let options: [(Int, String)] = [
        (0, t("照原样继续")),
        (1, t("睡眠时停止充电")),
        (2, t("睡眠时充满后停止充电"))
    ]

    private let lpmOptions: [(Int, String)] = [
        (0, t("始终关闭")),
        (1, t("始终开启")),
        (2, t("仅使用电池时")),
        (3, t("仅使用电源适配器时"))
    ]

    private let thresholdOptions: [(Int, String)] = [
        (0, t("低使用量")),
        (1, t("中等使用量（macOS 默认值）")),
        (2, t("高使用量"))
    ]

    private var lowPowerLeadOptions: [(Int, String)] {
        LowPowerPolicy.leadOptions.map { ($0, tf("{p} 分钟", "\($0)")) }
    }

    var body: some View {
        PageScaffold(title: Panel.sleep.title,
                     symbol: Panel.sleep.symbol,
                     help: t("MacBook 在睡眠时仍可能继续充电。选择一个行为，避免睡眠期间超出充电限制。")) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: t("防止睡眠期间过度充电"),
                               subtitle: t("选择 InfiniCal 在睡眠和充电时的行为方式"))
                    Picker("", selection: Binding(get: { state.sleepMode }, set: { state.sleepMode = $0 })) {
                        ForEach(Array(options.enumerated()), id: \.offset) { option in
                            Text(option.element.1).tag(option.element.0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(Glyph.row)
                            .foregroundColor(theme.textSecondary)
                        Text(t("注意：在睡眠状态下，InfiniCal 检查充电状态的时间会减少，因此如果您的 MacBook 在充电过程中进入睡眠状态，您可能会发现电量略微超过了限制。"))
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { advanced.value.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: advanced.value ? "chevron.down" : "chevron.right")
                        .font(Glyph.inline.weight(.semibold))
                    Text(t("显示高级设置"))
                        .font(Typography.body)
                }
                .foregroundColor(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if advanced.value {
                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "xmark.circle", title: t("应用程序关闭时停止充电"), help: t("退出 InfiniCal 时恢复系统默认充电行为。"), isOn: $state.exitInhibitCharge)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "zzz", title: t("完全禁用睡眠"), help: t("阻止系统空闲睡眠，保持监控不中断（会增加待机功耗）。合盖仍然会睡眠。"), isOn: $state.completelyDisableSleep)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "display", title: t("禁用睡眠时关闭显示器"), help: t("关闭后显示器也保持常亮；开启时只阻止系统睡眠，屏幕仍可关闭。"), isOn: $state.displayOffWhenSleepDisabled, disabled: !state.completelyDisableSleep)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "lock", title: t("合盖时锁定屏幕"), isOn: $state.lockScreenWhenClosed)
                    }
                }
            }

            Divider().background(theme.divider).padding(.vertical, 8)
            SectionLabel(text: t("能源使用"))
            PickerRow(symbol: "battery.25", title: t("低电量模式"), help: t("控制系统低电量模式的启用策略。"), selection: Binding(get: { state.lpmPreference }, set: { value in
                state.lpmPreference = value
                applyLowPowerMode(value)
            }), options: lpmOptions, width: 190)
            ToggleRow(symbol: "arrow.clockwise.circle", title: t("后台仪表板更新"), help: t("窗口在后台时也持续刷新仪表板数据。"), isOn: $state.dashboardBackgroundUpdates)

            SectionLabel(text: t("提醒"))
            Card {
                VStack(spacing: 4) {
                    // One state, not two: the switch is the same `disabled` set
                    // that 「关闭此类」 writes in 历史 → 异常告警. A separate
                    // `lowPowerAlertEnabled` flag would let the two disagree
                    // about whether the alert is on.
                    ToggleRow(symbol: "battery.25",
                              title: t("电量即将用尽时提醒"),
                              help: t("按最近 3 分钟的放电功率估算剩余时间，低于提前量时通知一次；电量低于 5% 也会提醒。"),
                              isOn: Binding(get: { !alerts.disabled.contains("lowPower") },
                                            set: { alerts.setDisabled("lowPower", !$0) }))
                    Divider().background(theme.divider)
                    PickerRow(symbol: "clock.badge.exclamationmark",
                              title: t("提前量"),
                              help: t("剩余可用时间少于这个值时提醒。"),
                              selection: $state.lowPowerLeadMinutes,
                              options: lowPowerLeadOptions,
                              width: 120)
                        .disabled(alerts.disabled.contains("lowPower"))
                        .opacity(alerts.disabled.contains("lowPower") ? 0.45 : 1)
                }
            }

            sleepReportCard

            HStack(spacing: 10) {
                IconBadge(symbol: "bolt.fill")
                Text(t("高功耗的应用程序")).font(Typography.headline).foregroundColor(theme.textPrimary)
                Spacer()
            }
            .frame(height: 34)
            .padding(.top, 8)

            Card {
                VStack(spacing: 4) {
                    PickerRow(symbol: "bolt", title: t("显示上方应用"), help: t("决定仪表板中列出哪些高能耗应用。"), selection: $state.energyThreshold, options: thresholdOptions, width: 200)
                    Divider().background(theme.divider)
                    ToggleRow(symbol: "gearshape", title: t("包含后台进程"), help: t("同时统计没有界面的后台进程。"), isOn: $state.showProcessesInHighUsage)
                }
            }

            if !state.highUsageApps.isEmpty {
                Card {
                    VStack(spacing: 8) {
                        ForEach(state.highUsageApps.prefix(6)) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                Text(app.name).font(Typography.body)
                                Spacer()
                                Text(String(format: "%.1f%%", app.energyImpact)).font(Typography.caption.monospacedDigit()).foregroundColor(theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sleep report

    /// "The lid was closed for eight hours and it lost 8 %" — the question this
    /// page could not answer before. Two samples per sleep, one row each; the
    /// figure is %/h so a 2-hour nap and a full night are comparable.
    private var sleepReportCard: some View {
        let summary = SleepAnalyzer.summarize(sleepSessions.sessions)
        let rows = SleepAnalyzer.recent(sleepSessions.sessions)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 10) {
                IconBadge(symbol: "moon.zzz")
                Text(t("睡眠耗电")).font(Typography.headline).foregroundColor(theme.textPrimary)
                Spacer()
                if let average = summary.averagePercentPerHour {
                    Text(String(format: "%.2f %%/h", average))
                        .font(Typography.caption.monospacedDigit())
                        .foregroundColor(theme.textSecondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    if rows.isEmpty {
                        Text(t("还没有可用的睡眠记录。合上盖子睡一次再唤醒，这里会按「时长 / 掉电 / 每小时」列出最近 14 次。"))
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if let advice = SleepAnalyzer.advice(summary) {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                                Image(systemName: summary.averagePercentPerHour ?? 0 > SleepReport.abnormalPercentPerHour
                                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(Glyph.inline)
                                    .foregroundColor((summary.averagePercentPerHour ?? 0) > SleepReport.abnormalPercentPerHour
                                                     ? theme.warning : theme.success)
                                Text(advice)
                                    .font(Typography.caption)
                                    .foregroundColor(theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        sleepTable(rows)
                        if summary.excluded > 0 {
                            Text(tf("另有 {p} 次睡眠期间电源状态发生变化，未计入每小时平均。", "\(summary.excluded)"))
                                .font(Typography.micro)
                                .foregroundColor(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func sleepTable(_ rows: [SleepSession]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(t("醒来时间")).frame(width: 96, alignment: .leading)
                Text(t("时长")).frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("电量")).frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("掉电")).frame(maxWidth: .infinity, alignment: .trailing)
                Text(t("每小时")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(Typography.label)
            .foregroundColor(theme.textTertiary)
            .frame(height: 22)
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    Text(Self.sleepFormatter.string(from: row.end))
                        .frame(width: 96, alignment: .leading)
                        .foregroundColor(theme.textPrimary)
                    Text(String(format: "%.1f h", row.hours))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\(row.startPercentage)→\(row.endPercentage)%")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\(row.lostPercentage) pp")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(row.percentPerHour.map { String(format: "%.2f", $0) } ?? "—")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Typography.caption.monospacedDigit())
                .foregroundColor(row.isAbnormal ? theme.warning : theme.textSecondary)
                .frame(height: 22)
            }
        }
    }

    private static let sleepFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private func applyLowPowerMode(_ value: Int) {
        let mode: ChargeController.LowPowerMode
        switch value {
        case 1: mode = .on
        case 2: mode = .batteryOnly
        case 3: mode = .adapterOnly
        default: mode = .off
        }
        do {
            try ChargeController.shared.setLowPowerMode(mode)
        } catch {
            state.lastMessage = error.localizedDescription
        }
    }
}
