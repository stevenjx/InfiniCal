//
//  PanelsBattery.swift  (睡眠与能源)
//

import SwiftUI

struct SleepEnergyView: View {
    @EnvironmentObject private var state: AppState
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
