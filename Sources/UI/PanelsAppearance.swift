//
//  PanelsAppearance.swift  (其他)
//

import SwiftUI

struct OtherView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }
    @StateObject private var about = UIFlag()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "circle.lefthalf.filled")
                    Text("外观模式")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    HStack(spacing: 18) {
                        appearanceDot(mode: 0, label: "系统", symbol: "circle.lefthalf.filled")
                        appearanceDot(mode: 1, label: "浅色", symbol: "sun.max.fill")
                        appearanceDot(mode: 2, label: "深色", symbol: "moon.fill")
                    }
                }
                .frame(height: 44)

                Text("合盖模式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "laptopcomputer", title: "合盖时保持唤醒", help: "合上盖子时阻止系统睡眠，方便外接显示器使用。", isOn: $state.completelyDisableSleep)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "display", title: "关闭内建显示器", isOn: $state.displayOffWhenSleepDisabled)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "lock", title: "合盖时锁定屏幕", isOn: $state.lockScreenWhenClosed)
                    }
                }

                Text("管理许可证")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    HStack {
                        Text("InfiniCal 专业版功能已全部解锁")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("本地授权")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Card {
                    HStack(spacing: 8) {
                        SmallActionButton(title: "简介", symbol: "info.circle") { about.value = true }
                        Spacer()
                    }
                }

                Text("功率数据源")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 6) {
                        powerSourceRow("电源适配器输入", "SMC PSTR · 1 Hz", quality: state.snapshot.isPluggedIn ? .measured : .unavailable)
                        powerSourceRow("MacBook 总功耗", "PSTR − 电池充电", quality: .measured)
                        powerSourceRow("电池充放电", "Voltage × Amperage", quality: .measured)
                        powerSourceRow("1 分钟均值", "SystemLoad（60 s 快照）", quality: state.livePower.isLive ? .estimated : .measured)
                        powerSourceRow("SoC", sourceName(for: state.soc), quality: state.soc.quality)
                        powerSourceRow("显示", sourceName(for: state.displayPower), quality: state.displayPower.quality)
                        powerSourceRow("USB", "无可用数据源", quality: .unavailable)
                        Divider().background(theme.divider)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 9))
                            Text("「其他」= MacBook 总功耗 − 已知分项，属于残差而不是独立测量值。")
                                .font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(theme.textTertiary)
                    }
                }

                if state.capabilities.strategy == .unavailable || !state.helperInstalled {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("充电控制状态")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.textPrimary)
                            Text(state.capabilities.summary)
                                .font(.system(size: 11))
                                .foregroundColor(theme.textSecondary)
                            if !state.helperInstalled {
                                Button { state.installHelper() } label: {
                                    Text("安装特权助手")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(theme.accent))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("InfiniCal 1.0.0")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                    Spacer()
                    Text("© 2026 Infinity Computer")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                }
                .padding(.top, 10)
            }
            .padding(22)
        }
        .sheet(isPresented: $about.value) {
            VStack(spacing: 10) {
                Image(systemName: "battery.100.bolt")
                    .font(.system(size: 34))
                    .foregroundColor(theme.accent)
                Text("InfiniCal 1.0.0").font(.system(size: 14, weight: .semibold))
                Text("电池充电管理工具\n适配 Intel 与 Apple Silicon，支持 macOS 12 及以上。")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundColor(theme.textSecondary)
                Button("好") { about.value = false }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accent)
                    .padding(.top, 6)
            }
            .padding(24)
            .frame(width: 300)
        }
    }

    private func sourceName(for reading: PowerReading) -> String {
        switch reading.quality {
        case .measured: return "powermetrics"
        case .estimated: return "亮度/占用率模型"
        case .unavailable: return "无可用数据源"
        }
    }

    private func powerSourceRow(_ title: String, _ source: String, quality: PowerQuality) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: quality)).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11)).foregroundColor(theme.textPrimary)
            Spacer()
            Text(source).font(.system(size: 9, design: .monospaced)).foregroundColor(theme.textTertiary)
            Text(quality.badge).font(.system(size: 9, weight: .medium)).foregroundColor(color(for: quality)).frame(width: 34, alignment: .trailing)
        }
    }

    private func color(for quality: PowerQuality) -> Color {
        switch quality {
        case .measured: return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .estimated: return Color(red: 0.95, green: 0.72, blue: 0.30)
        case .unavailable: return theme.textTertiary
        }
    }

    private func appearanceDot(mode: Int, label: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Button { state.colorMode = mode } label: {
                Circle()
                    .fill(mode == 0 ? theme.innerControl : (mode == 1 ? Color.white : Color.black))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(state.colorMode == mode ? theme.accent : theme.cardStroke, lineWidth: state.colorMode == mode ? 2 : 1))
                    .overlay(Image(systemName: symbol).font(.system(size: 8)).foregroundColor(mode == 1 ? .black : .white))
            }
            .buttonStyle(.plain)
            Text(label).font(.system(size: 9)).foregroundColor(theme.textSecondary)
        }
    }
}
