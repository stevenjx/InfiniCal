//
//  PanelsAppearance.swift  (其他)
//

import SwiftUI

struct OtherView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "circle.lefthalf.filled")
                    Text(t("外观模式"))
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    segmentControl(selection: $state.colorMode,
                                   options: [SegmentOption(id: 0, symbol: "circle.lefthalf.filled", title: t("系统")),
                                             SegmentOption(id: 1, symbol: "sun.max.fill", title: t("浅色")),
                                             SegmentOption(id: 2, symbol: "moon.fill", title: t("深色"))])
                }
                .frame(height: 46)

                HStack(spacing: 10) {
                    IconBadge(symbol: "globe")
                    Text(t("语言"))
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    segmentControl(selection: $state.languageMode,
                                   options: [SegmentOption(id: 0, symbol: nil, title: t("系统")),
                                             SegmentOption(id: 1, symbol: nil, title: "中文"),
                                             SegmentOption(id: 2, symbol: nil, title: "English")])
                }
                .frame(height: 46)

                Text(t("合盖模式"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "laptopcomputer", title: t("合盖时保持唤醒"), help: t("合上盖子时阻止系统睡眠，方便外接显示器使用。"), isOn: $state.completelyDisableSleep)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "display", title: t("关闭内建显示器"), isOn: $state.displayOffWhenSleepDisabled)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "lock", title: t("合盖时锁定屏幕"), isOn: $state.lockScreenWhenClosed)
                    }
                }

                Text(t("通用"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "dock.rectangle",
                                  title: t("在 Dock 中显示图标"),
                                  help: t("关闭后应用只在菜单栏显示，不占用 Dock 与 Cmd-Tab。"),
                                  isOn: $state.showInDock)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "power.circle",
                                  title: t("开机时自动启动"),
                                  help: t("登录 macOS 后自动运行，让充电限制与风扇策略持续生效。"),
                                  isOn: $state.launchAtLogin)
                    }
                }

                Text(t("功率数据源"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 6) {
                        powerSourceRow(t("电源适配器输入"), "SMC PSTR · 1 Hz", quality: state.snapshot.isPluggedIn ? .measured : .unavailable)
                        powerSourceRow(t("MacBook 总功耗"), t("PSTR − 电池充电"), quality: .measured)
                        powerSourceRow(t("电池充放电"), "Voltage × Amperage", quality: .measured)
                        powerSourceRow(t("1 分钟均值"), t("SystemLoad（60 s 快照）"), quality: state.livePower.isLive ? .estimated : .measured)
                        powerSourceRow("SoC", sourceName(for: state.soc), quality: state.soc.quality)
                        powerSourceRow(t("显示"), sourceName(for: state.displayPower), quality: state.displayPower.quality)
                        powerSourceRow("USB", t("无可用数据源"), quality: .unavailable)
                        Divider().background(theme.divider)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle").font(.system(size: 9))
                            Text(t("「其他」= MacBook 总功耗 − 已知分项，属于残差而不是独立测量值。"))
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
                            Text(t("充电控制状态"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.textPrimary)
                            Text(state.capabilities.summary)
                                .font(.system(size: 11))
                                .foregroundColor(theme.textSecondary)
                            if !state.helperInstalled {
                                Button { state.installHelper() } label: {
                                    Text(t("安装特权助手"))
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
                    Text("InfiniCal \(Self.appVersion)")
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
    }

    private func sourceName(for reading: PowerReading) -> String {
        switch reading.quality {
        case .measured: return "powermetrics"
        case .estimated: return t("亮度/占用率模型")
        case .unavailable: return t("无可用数据源")
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

    /// Read from the bundle so a version bump can never leave stale text here.
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private struct SegmentOption: Identifiable {
        let id: Int
        /// `character` / `textformat` render as the glyphs “字” and “格式” in a
        /// Chinese system, which read as stray text inside the pill — so the
        /// language segments carry no icon at all.
        let symbol: String?
        let title: String
    }

    /// One pill per row, both 216 pt wide so the two right edges line up. Icons
    /// stay legible here — inside the old 20 pt circles they read as smudges.
    private func segmentControl(selection: Binding<Int>, options: [SegmentOption]) -> some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { selection.wrappedValue = option.id } label: {
                    HStack(spacing: 4) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text(option.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundColor(selection.wrappedValue == option.id ? .white : theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection.wrappedValue == option.id ? theme.accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(width: 216)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.innerControl))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 1))
    }
}
