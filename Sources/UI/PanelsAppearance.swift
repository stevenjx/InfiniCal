//
//  PanelsAppearance.swift  (其他)
//

import SwiftUI

struct OtherView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var showingDiagnostics = UIFlag()
    @StateObject private var showingUpdates = UIFlag()
    @ObservedObject private var updater = SparkleUpdater.shared
    private var theme: Theme { Theme.current }

    var body: some View {
        PageScaffold(title: Panel.other.title,
                     symbol: Panel.other.symbol,
                     toolbar: { headerToolbar }) {
            HStack(spacing: 10) {
                IconBadge(symbol: "circle.lefthalf.filled")
                Text(t("外观模式"))
                    .font(Typography.headline)
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
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                segmentControl(selection: $state.languageMode,
                               options: [SegmentOption(id: 0, symbol: nil, title: t("系统")),
                                         SegmentOption(id: 1, symbol: nil, title: "中文"),
                                         SegmentOption(id: 2, symbol: nil, title: "English")])
            }
            .frame(height: 46)

            Text(t("合盖模式"))
                .font(Typography.label.weight(.semibold))
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
                .font(Typography.label.weight(.semibold))
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
                    Divider().background(theme.divider)
                    ToggleRow(symbol: "arrow.triangle.2.circlepath",
                              title: t("自动检查更新"),
                              help: t("启用后，Sparkle 会按系统节奏在后台查询 appcast；发现新版本时提示你确认后才会下载。"),
                              isOn: $updater.automaticallyChecks)
                }
            }

            Text(t("功率数据源"))
                .font(Typography.label.weight(.semibold))
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
                        Image(systemName: "info.circle").font(Glyph.inline)
                        Text(t("「其他」= MacBook 总功耗 − 已知分项，属于残差而不是独立测量值。"))
                            .font(Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(theme.textTertiary)
                }
            }

            if state.capabilities.strategy == .unavailable || !state.helperInstalled {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(title: t("充电控制状态"),
                                   subtitle: state.capabilities.summary)
                        if !state.helperInstalled {
                            Button { state.installHelper() } label: {
                                Text(t("安装特权助手"))
                                    .font(Typography.label)
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
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                Spacer()
                Text("© 2026 Infinity Computer")
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
            .padding(.top, 10)
        }
    }

    /// Diagnostics and update check: the page's toolbar, right of the title.
    private var headerToolbar: some View {
        HStack(spacing: Spacing.s) {
            Button(t("硬件兼容性诊断")) { showingDiagnostics.value = true }
                .sheet(isPresented: $showingDiagnostics.value) { HardwareDiagnosticsView() }
            Button(t("检查更新")) {
                updater.checkForUpdates()
                showingUpdates.value = true
            }
            .sheet(isPresented: $showingUpdates.value) { UpdateSheet() }
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
            Text(title).font(Typography.caption).foregroundColor(theme.textPrimary)
            Spacer()
            Text(source).font(Typography.micro.monospaced()).foregroundColor(theme.textTertiary)
            Text(quality.badge).font(Typography.micro).foregroundColor(color(for: quality)).frame(width: 34, alignment: .trailing)
        }
    }

    private func color(for quality: PowerQuality) -> Color {
        switch quality {
        case .measured: return theme.success
        case .estimated: return theme.warning
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
                                .font(Glyph.inline.weight(.semibold))
                        }
                        Text(option.title)
                            .font(Typography.caption)
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
