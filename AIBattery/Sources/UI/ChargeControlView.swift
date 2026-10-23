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
                    HelpDot(text: "设置电池允许充到的最高电量。达到该数值后 AIBattery 会暂停充电，让 MacBook 直接使用电源适配器供电。")
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

                Divider().background(theme.divider).padding(.vertical, 8)

                HStack(spacing: 10) {
                    IconBadge(symbol: "slider.horizontal.3")
                    Text("校准模式")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "校准会完整充放电一次，让电量计重新学习电池的真实容量。过程需要数小时，期间请保持电源连接。")
                    Spacer()
                    Button {
                        if state.calibration == nil { state.startCalibration() } else { state.stopCalibration() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: state.calibration == nil ? "play.fill" : "stop.fill")
                                .font(.system(size: 10))
                            Text(state.calibration == nil ? "开始校准" : "停止校准")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.innerControl))
                        .foregroundColor(theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 34)

                Card(padding: 16) {
                    HStack(spacing: 0) {
                        ForEach(Array(CalibrationStage.allCases.enumerated()), id: \.offset) { item in
                            VStack(spacing: 8) {
                                BatteryGlyph(fill: fillFraction(for: item.element),
                                             accent: item.element == .hold ? theme.chartBlue : theme.chartGreen,
                                             overlay: overlay(for: item.element))
                                    .frame(width: 26, height: 40)
                                Text(item.element.title)
                                    .font(.system(size: 10))
                                    .foregroundColor(isActive(item.element) ? theme.textPrimary : theme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 62)
                            }
                            .frame(maxWidth: .infinity)
                            if item.offset < CalibrationStage.allCases.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.textTertiary)
                                    .padding(.horizontal, 2)
                                    .offset(y: -10)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Text("上次校准: \(state.lastCalibrationDate.map { Self.formatter.string(from: $0) } ?? "-")")
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }
                .padding(.top, 4)

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

    private func fillFraction(for stage: CalibrationStage) -> Double {
        switch stage {
        case .chargeToFull, .chargeToFullAgain: return 1.0
        case .dischargeToTen: return 0.1
        case .hold: return 1.0
        case .dischargeToLimit: return Double(state.calibrationBackup) / 100.0
        }
    }

    private func overlay(for stage: CalibrationStage) -> String? {
        switch stage {
        case .hold: return "pause.fill"
        case .chargeToFull, .chargeToFullAgain: return "plus"
        default: return nil
        }
    }

    private func isActive(_ stage: CalibrationStage) -> Bool {
        state.calibration?.stage == stage
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()
}

struct BatteryGlyph: View {
    private var theme: Theme { Theme.current }
    var fill: Double
    var accent: Color = .green
    var overlay: String? = nil

    var body: some View {
        let w: CGFloat = 24
        let h: CGFloat = 38
        let inner = h - 6
        let filled = max(2, inner * CGFloat(min(max(fill, 0), 1)))
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(theme.textTertiary.opacity(0.85), lineWidth: 1.2)
                .frame(width: w, height: h)
            RoundedRectangle(cornerRadius: 1.2)
                .fill(theme.textTertiary.opacity(0.85))
                .frame(width: 8, height: 2.5)
                .offset(y: -(h / 2 + 2))
            RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                .fill(accent)
                .frame(width: w - 6, height: filled)
                .offset(y: (inner / 2) - filled / 2)
            if let overlay {
                Image(systemName: overlay)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 30, height: 44)
    }
}
