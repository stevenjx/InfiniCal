//
//  ChargeControlView.swift
//

import SwiftUI

struct ChargeControlView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "battery.75")
                    Text(t("充电限制"))
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: t("设置电池允许充到的最高电量。达到该数值后 InfiniCal 会暂停充电，让 MacBook 直接使用电源适配器供电。"))
                    Spacer()
                    ValueStepper(value: Binding(get: { state.chargeVal },
                                                set: { state.userSetLimit($0) }),
                                 range: state.allowBelow80 && ChargeController.shared.canSetBelow80 ? 1...100 : 80...100,
                                 step: 5)
                        .frame(width: 108)
                }
                .frame(height: 34)

                if let restore = state.topUpRestoreLimit {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accent)
                        Text(tf("一次性充满至 100%，完成后恢复 {p}%", "\(restore)"))
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Button(t("取消")) { state.cancelTopUp() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.innerControl))
                }

                ToggleRow(symbol: "exclamationmark.triangle",
                          title: t("允许充电上限低于 80%"),
                          help: t("关闭后，充电限制最低只能设置为 80%。"),
                          isOn: Binding(get: { state.allowBelow80 },
                                        set: { state.allowBelow80 = $0 }))

                ToggleRow(symbol: "bolt.slash",
                          title: t("自动放电"),
                          help: t("当电池电量高于充电限制时，自动放电至限制值。"),
                          isOn: $state.automaticDischarge)

                ToggleRow(symbol: "sailboat",
                          title: t("航海模式"),
                          help: t("电池电量低于「充电限制 − 差异」时自动恢复充电，避免频繁插拔。"),
                          isOn: $state.sailingMode)

                if state.sailingMode {
                    Card(padding: 14) {
                        HStack(spacing: 8) {
                            Spacer()
                            Text(t("差异:"))
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                            ValueStepper(value: $state.sailingLevel, range: 1...max(1, min(30, state.chargeVal - 1)), step: 1)
                                .frame(width: 92)
                            Text(tf("→ 将航海至 {p}%.", "\(max(1, state.chargeVal - state.sailingLevel))"))
                                .font(.system(size: 12))
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                        }
                    }
                }

                ToggleRow(symbol: "flame",
                          title: t("过热保护"),
                          help: t("电池温度超过上限时暂停充电，冷却后自动恢复。"),
                          isOn: $state.heatProtectMode)

                Card(padding: 14) {
                    HStack {
                        Spacer()
                        Text(state.heatProtectMode
                             ? tf("过热保护已开启。 温度上限: {p}°C。 当前温度: {p}", "\(state.maxTemperature)", String(format: "%.1f°C", state.snapshot.temperature))
                             : tf("过热保护已关闭。 当前温度: {p}", String(format: "%.1f°C", state.snapshot.temperature)))
                            .font(.system(size: 12))
                            .foregroundColor(theme.textSecondary)
                        if state.heatProtectMode {
                            ValueStepper(value: $state.maxTemperature, range: 25...60, step: 1, suffix: "°C")
                                .frame(width: 100)
                                .padding(.leading, 8)
                        }
                        Spacer()
                    }
                }

                if let adapter = state.adapterDiagnosis {
                    Divider().background(theme.divider).padding(.vertical, 6)
                    SectionLabel(text: t("电源适配器"))
                    adapterCard(adapter)
                }

                Divider().background(theme.divider).padding(.vertical, 6)
                SectionLabel(text: t("按时间充满"))
                smartChargeCard

                if !state.helperInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Text(tf("写入 SMC 需要特权助手（当前策略：{p}）", state.capabilities.strategy.title))
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Button {
                            state.installHelper()
                        } label: {
                            Text(t("安装"))
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(theme.accent))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                }

                if state.statusNote.isEmpty == false {
                    Text(state.statusNote)
                        .font(.system(size: 11))
                        .foregroundColor(theme.textTertiary)
                        .padding(.top, 6)
                }
            }
            .padding(22)
        }
    }

    // MARK: - Adapter

    private func adapterCard(_ adapter: AppState.AdapterDiagnosis) -> some View {
        let status = adapterStatus(adapter)
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(tf("输入 {p}", watts(adapter.inputWatts)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(theme.textPrimary)
                    if adapter.ratedWatts > 0 {
                        Text(tf("· 额定 {p} W", "\(Int(adapter.ratedWatts))"))
                            .font(.system(size: 10))
                            .foregroundColor(theme.textTertiary)
                    }
                    Spacer()
                    Text(status.0)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(status.1.opacity(0.15)))
                        .foregroundColor(status.1)
                }

                HStack(spacing: 0) {
                    adapterMetric(t("系统"), watts(adapter.systemWatts), theme.chartBlue)
                    adapterMetric(t("电池"), batteryText(adapter.batteryWatts),
                                  adapter.batteryWatts < 0 ? Color(red: 1, green: 0.27, blue: 0.23) : theme.chartGreen)
                    if adapter.ratedWatts > 0 {
                        adapterMetric(t("余量"), signedWatts(adapter.headroomWatts),
                                      adapter.headroomWatts < 0
                                        ? Color(red: 1, green: 0.27, blue: 0.23)
                                        : (adapter.level == .tight ? theme.chartOrange : theme.textSecondary))
                    }
                }

                if adapter.lossWatts > 0.05 {
                    Text(String(format: t("适配器转换损耗 %.1f W（%.0f%%）"), adapter.lossWatts, adapter.lossPercent))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                }

                if adapter.level == .insufficient {
                    Text(t("当前适配器功率低于系统负载，电池正在放电。换用更大功率的适配器或降低负载。"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adapterMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(theme.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adapterStatus(_ adapter: AppState.AdapterDiagnosis) -> (String, Color) {
        switch adapter.level {
        case .good: return (t("余量充足"), theme.chartGreen)
        case .tight: return (t("接近满载"), theme.chartOrange)
        case .insufficient: return (t("功率不足"), Color(red: 1, green: 0.27, blue: 0.23))
        }
    }

    private func batteryText(_ value: Double) -> String {
        value >= 0 ? String(format: t("充 %.1f W"), value) : String(format: t("放 %.1f W"), -value)
    }

    private func watts(_ value: Double) -> String { String(format: "%.1f W", value) }

    private func signedWatts(_ value: Double) -> String {
        value < 0 ? String(format: "-%.1f W", -value) : String(format: "%.1f W", value)
    }

    // MARK: - Smart charge

    private var smartChargeCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ToggleRow(symbol: "clock.badge.checkmark",
                          title: t("在指定时间充满"),
                          help: t("其余时间维持上面的充电上限，只在目标时间前把电充满，减少满电静置。开始时间按当前电量与实测充电功率反推。"),
                          isOn: $state.smartChargeEnabled)

                if state.smartChargeEnabled {
                    HStack(spacing: 8) {
                        Text(t("目标时间"))
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Picker("", selection: $state.smartChargeHour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        Picker("", selection: $state.smartChargeMinute) {
                            ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }

                    Text(state.smartChargeStatusText)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if state.chargeRateWatts > 0.5 {
                        Text(String(format: t("按实测充电功率 %.0f W 估算"), state.chargeRateWatts))
                            .font(.system(size: 9))
                            .foregroundColor(theme.textTertiary)
                    }
                }
            }
        }
    }
}
