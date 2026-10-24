//
//  PanelsBattery.swift  (睡眠与能源)
//

import SwiftUI

struct SleepEnergyView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }
    @StateObject private var advanced = UIFlag()

    private let options: [(Int, String)] = [
        (0, "照原样继续"),
        (1, "睡眠时停止充电"),
        (2, "睡眠时充满后停止充电")
    ]

    private let lpmOptions: [(Int, String)] = [
        (0, "始终关闭"),
        (1, "始终开启"),
        (2, "仅使用电池时"),
        (3, "仅使用电源适配器时")
    ]

    private let thresholdOptions: [(Int, String)] = [
        (0, "低使用量"),
        (1, "中等使用量（macOS 默认值）"),
        (2, "高使用量")
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "moon")
                    Text("防止睡眠期间过度充电")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "MacBook 在睡眠时仍可能继续充电。选择一个行为，避免睡眠期间超出充电限制。")
                    Spacer()
                }
                .frame(height: 34)

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("选择 InfiniCal 在睡眠和充电时的行为方式")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
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
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                            Text("注意：在睡眠状态下，InfiniCal 检查充电状态的时间会减少，因此如果您的 MacBook 在充电过程中进入睡眠状态，您可能会发现电量略微超过了限制。")
                                .font(.system(size: 11))
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
                            .font(.system(size: 10, weight: .semibold))
                        Text("显示高级设置")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                if advanced.value {
                    Card {
                        VStack(spacing: 4) {
                            ToggleRow(symbol: "moon.zzz", title: "睡眠时停止充电", help: "MacBook 进入睡眠时立即暂停充电。", isOn: $state.sleepInhibitCharge)
                            Divider().background(theme.divider)
                            ToggleRow(symbol: "xmark.circle", title: "应用程序关闭时停止充电", help: "退出 InfiniCal 时恢复系统默认充电行为。", isOn: $state.exitInhibitCharge)
                            Divider().background(theme.divider)
                            ToggleRow(symbol: "zzz", title: "完全禁用睡眠", help: "保持 MacBook 唤醒以便持续监控电池状态（会增加待机功耗）。", isOn: $state.completelyDisableSleep)
                            Divider().background(theme.divider)
                            ToggleRow(symbol: "display", title: "禁用睡眠时关闭显示器", isOn: $state.displayOffWhenSleepDisabled)
                            Divider().background(theme.divider)
                            ToggleRow(symbol: "lock", title: "合盖时锁定屏幕", isOn: $state.lockScreenWhenClosed)
                        }
                    }
                }

                Divider().background(theme.divider).padding(.vertical, 8)
                SectionLabel(text: "能源使用")
                PickerRow(symbol: "battery.25", title: "低电量模式", help: "控制系统低电量模式的启用策略。", selection: Binding(get: { state.lpmPreference }, set: { value in
                    state.lpmPreference = value
                    applyLowPowerMode(value)
                }), options: lpmOptions, width: 190)
                ToggleRow(symbol: "arrow.clockwise.circle", title: "后台仪表板更新", help: "窗口在后台时也持续刷新仪表板数据。", isOn: $state.dashboardBackgroundUpdates)

                HStack(spacing: 10) {
                    IconBadge(symbol: "bolt.fill")
                    Text("高功耗的应用程序").font(.system(size: 13)).foregroundColor(theme.textPrimary)
                    Spacer()
                }
                .frame(height: 34)
                .padding(.top, 8)

                Card {
                    VStack(spacing: 4) {
                        PickerRow(symbol: "bolt", title: "显示上方应用", help: "决定仪表板中列出哪些高能耗应用。", selection: $state.energyThreshold, options: thresholdOptions, width: 200)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "gearshape", title: "包含后台进程", help: "同时统计没有界面的后台进程。", isOn: $state.showProcessesInHighUsage)
                    }
                }

                if !state.highUsageApps.isEmpty {
                    Card {
                        VStack(spacing: 8) {
                            ForEach(state.highUsageApps.prefix(6)) { app in
                                HStack(spacing: 8) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                    Text(app.name).font(.system(size: 12))
                                    Spacer()
                                    Text(String(format: "%.1f%%", app.energyImpact)).font(.system(size: 11).monospacedDigit()).foregroundColor(theme.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
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
