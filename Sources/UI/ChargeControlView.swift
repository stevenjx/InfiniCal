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
                    Text("充电限制")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "设置电池允许充到的最高电量。达到该数值后 InfiniCal 会暂停充电，让 MacBook 直接使用电源适配器供电。")
                    Spacer()
                    ValueStepper(value: $state.chargeVal, range: 0...100, step: 5)
                        .frame(width: 108)
                }
                .frame(height: 34)

                ToggleRow(symbol: "exclamationmark.triangle",
                          title: "允许充电至低于 \(state.chargeVal)% 的电量",
                          help: "关闭后，充电限制最低只能设置为 80%。",
                          isOn: Binding(get: { state.allowBelow80 },
                                        set: { state.allowBelow80 = $0 }))

                ToggleRow(symbol: "bolt.slash",
                          title: "自动放电",
                          help: "当电池电量高于充电限制时，自动放电至限制值。",
                          isOn: $state.automaticDischarge)

                ToggleRow(symbol: "sailboat",
                          title: "航海模式",
                          help: "电池电量低于「充电限制 − 差异」时自动恢复充电，避免频繁插拔。",
                          isOn: $state.sailingMode)

                if state.sailingMode {
                    Card(padding: 14) {
                        HStack(spacing: 8) {
                            Spacer()
                            Text("差异:")
                                .font(.system(size: 12))
                                .foregroundColor(theme.textSecondary)
                            ValueStepper(value: $state.sailingLevel, range: 1...30, step: 1)
                                .frame(width: 92)
                            Text("→ 将航海至 \(max(0, state.chargeVal - state.sailingLevel))%.")
                                .font(.system(size: 12))
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                        }
                    }
                }

                ToggleRow(symbol: "flame",
                          title: "过热保护",
                          help: "电池温度超过上限时暂停充电，冷却后自动恢复。",
                          isOn: $state.heatProtectMode)

                Card(padding: 14) {
                    HStack {
                        Spacer()
                        Text(state.heatProtectMode
                             ? "过热保护已开启。 温度上限: \(state.maxTemperature)°C。 当前温度: \(String(format: "%.1f°C", state.snapshot.temperature))"
                             : "过热保护已关闭。 当前温度: \(String(format: "%.1f°C", state.snapshot.temperature))")
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

                if !state.helperInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Text("写入 SMC 需要特权助手（当前策略：\(state.capabilities.strategy.title)）")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Button {
                            state.installHelper()
                        } label: {
                            Text("安装")
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
}
