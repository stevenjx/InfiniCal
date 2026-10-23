//
//  PanelsAppearance.swift  (翻盖 / 菜单栏 / 其他)
//

import SwiftUI

struct ClamshellView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ToggleRow(symbol: "eye",
                          title: "启动时显示",
                          help: "登录时自动打开主窗口。",
                          isOn: $state.showGUIonStartup)

                ToggleRow(symbol: "percent",
                          title: "显示百分比",
                          help: "在弹出窗口中显示电池百分比。",
                          isOn: $state.showPercentage)

                Button {
                    NotificationCenter.default.post(name: .openPopoverEditMode, object: nil)
                } label: {
                    Text("在编辑模式下打开")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.innerControl))
                        .foregroundColor(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
                .padding(.top, 2)

                Divider().background(theme.divider).padding(.vertical, 10)

                Text("合盖模式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)

                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "laptopcomputer",
                                  title: "合盖时保持唤醒",
                                  help: "合上盖子时阻止系统睡眠，方便外接显示器使用。",
                                  isOn: $state.completelyDisableSleep)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "display",
                                  title: "关闭内建显示器",
                                  isOn: $state.displayOffWhenSleepDisabled)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "lock",
                                  title: "合盖时锁定屏幕",
                                  isOn: $state.lockScreenWhenClosed)
                    }
                }
            }
            .padding(22)
        }
    }
}

struct MenuBarSettingsView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    private let styles = ["不要显示", "AIBattery 图标", "AIBattery 状态", "macOS 电池"]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "menubar.rectangle")
                    Text("选定的菜单项")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "这些项目会依次显示在菜单栏图标右侧。")
                    Spacer()
                }
                .frame(height: 34)

                Card(padding: 14) {
                    Text(menuBarPreview)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.innerControl))
                }

                HStack(spacing: 10) {
                    IconBadge(symbol: "book")
                    Text("菜单项目录")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                }
                .frame(height: 34)
                .padding(.top, 4)

                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("主图标样式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.textPrimary)
                        HStack(spacing: 8) {
                            ForEach(Array(styles.enumerated()), id: \.offset) { item in
                                ChipButton(title: item.element,
                                           symbol: item.offset == 0 ? "eye.slash" : (item.offset == 1 ? "app" : "battery.75"),
                                           selected: state.menuBarIconStyle == item.offset) {
                                    state.menuBarIconStyle = item.offset
                                }
                            }
                        }

                        Text("主图标选项")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.textPrimary)
                        HStack(spacing: 8) {
                            ChipButton(title: "显示百分比", symbol: "percent", selected: state.showPercentage) {
                                state.showPercentage.toggle()
                            }
                            ChipButton(title: "低电量模式颜色", symbol: "paintpalette", selected: state.lpmMenuBarColor) {
                                state.lpmMenuBarColor.toggle()
                            }
                        }

                        chipSection("电池健康", items: [.maxCapacity, .macOSCondition, .cycleCount])
                        chipSection("电池规格", items: [.hardwarePercentage, .temperature, .timeRemaining, .current, .voltage])
                        chipSection("电源适配器规格", items: [.adapterCurrent, .adapterVoltage, .adapterPower])
                        chipSection("AIBattery 状态", items: [.calibration, .heatProtection, .sailing, .topUp])

                        Divider().background(theme.divider)
                        HStack {
                            Spacer()
                            Button {
                                state.selectedMenuBarItems = []
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                                    Text("重置").font(.system(size: 11))
                                }
                                .foregroundColor(theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            Button {
                                state.selectedMenuBarItems = []
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "trash").font(.system(size: 10))
                                    Text("全部清除").font(.system(size: 11))
                                }
                                .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 14)
                        }
                    }
                }

                HStack(spacing: 10) {
                    IconBadge(symbol: "arrow.left.and.right")
                    Text("菜单项间距")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: "调整菜单栏项目之间的间距。")
                    Spacer()
                    Text("0").font(.system(size: 10)).foregroundColor(theme.textTertiary)
                    Slider(value: Binding(get: { Double(state.menuBarSpacing) },
                                          set: { state.menuBarSpacing = Int($0) }), in: 0...20, step: 1)
                        .frame(width: 160)
                        .tint(theme.accent)
                    Text("20").font(.system(size: 10)).foregroundColor(theme.textTertiary)
                }
                .frame(height: 34)
            }
            .padding(22)
        }
    }

    private func chipSection(_ title: String, items: [MenuBarItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.textPrimary)
            HStack(spacing: 8) {
                ForEach(items) { item in
                    ChipButton(title: item.title,
                               symbol: item.symbol,
                               selected: state.selectedMenuBarItems.contains(item.rawValue)) {
                        if state.selectedMenuBarItems.contains(item.rawValue) {
                            state.selectedMenuBarItems.remove(item.rawValue)
                        } else {
                            state.selectedMenuBarItems.insert(item.rawValue)
                        }
                    }
                }
            }
        }
    }

    private var menuBarPreview: String {
        var parts: [String] = []
        if state.showPercentage { parts.append("\(state.snapshot.percentage)%") }
        if state.selectedMenuBarItems.contains(MenuBarItem.temperature.rawValue) {
            parts.append(String(format: "%.0f°C", state.snapshot.temperature))
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.cycleCount.rawValue) {
            parts.append("\(state.snapshot.cycleCount)")
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.maxCapacity.rawValue) {
            parts.append("\(state.snapshot.healthPercent)%")
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.sailing.rawValue) { parts.append("⛵") }
        if state.selectedMenuBarItems.contains(MenuBarItem.heatProtection.rawValue) { parts.append("🔥") }
        let status = state.chargeState == .charging ? "⚡" : "⏸"
        return (parts.isEmpty ? "" : parts.joined(separator: "  ") + "  ") + status
    }
}

struct OtherView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }
    @StateObject private var about = UIFlag()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ToggleRow(symbol: "dock.rectangle",
                          title: "显示程序坞图标",
                          help: "在程序坞中显示 AIBattery。",
                          isOn: $state.showDockIcon)

                ToggleRow(symbol: "drop",
                          title: "降低透明度",
                          help: "使用不透明的窗口背景。",
                          isOn: $state.reduceTransparency)

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

                HStack(spacing: 10) {
                    IconBadge(symbol: "light.max")
                    Text("Magsafe LED")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                }
                .frame(height: 30)
                .padding(.top, 4)

                Card {
                    VStack(spacing: 4) {
                        HStack(spacing: 10) {
                            IconBadge(symbol: "lightbulb")
                            Text("LED 设置")
                                .font(.system(size: 13))
                                .foregroundColor(theme.textPrimary)
                            Spacer()
                            Picker("", selection: Binding(get: { state.magsafeOff ? MagSafeLED.off : MagSafeLED.system },
                                                          set: { value in
                                                              state.magsafeOff = (value == .off)
                                                              try? ChargeController.shared.setMagSafeLED(value)
                                                          })) {
                                ForEach(MagSafeLED.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 130)
                        }
                        .frame(height: 30)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "battery.100.bolt",
                                  title: "指示充电限制",
                                  help: "用 LED 颜色表示电池是否达到充电限制。",
                                  isOn: $state.magsafeControl)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "sparkles",
                                  title: "放电期间闪烁橙色",
                                  isOn: $state.magsafeBlinkDischarge)
                    }
                }

                Text("快捷功能")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            SmallActionButton(title: "简介", symbol: "info.circle") { about.value = true }
                            SmallActionButton(title: "保存调试文件", symbol: "square.and.arrow.down") { saveDebugFile() }
                        }
                        HStack(spacing: 8) {
                            SmallActionButton(title: "恢复默认设置", symbol: "arrow.counterclockwise") { restoreDefaults() }
                            SmallActionButton(title: "删除 AIBattery", symbol: "trash", destructive: true) {
                                state.lastMessage = "请在 Finder 中将 AIBattery.app 移到废纸篓"
                            }
                        }
                    }
                }

                Text("管理许可证")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    HStack {
                        Text("AIBattery 专业版功能已全部解锁")
                            .font(.system(size: 12))
                            .foregroundColor(theme.textPrimary)
                        Spacer()
                        Text("本地授权")
                            .font(.system(size: 11))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                Text("更新")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            SmallActionButton(title: "检查更新", symbol: "arrow.triangle.2.circlepath") {
                                state.lastMessage = "当前已是最新版本"
                            }
                            HStack {
                                Text("自动检查").font(.system(size: 12))
                                Spacer()
                                Toggle("", isOn: $state.checkForUpdates)
                                    .labelsHidden().toggleStyle(.switch).tint(theme.accent)
                                    .scaleEffect(0.72).frame(width: 36, height: 20)
                            }
                        }
                        HStack(spacing: 8) {
                            SmallActionButton(title: "有什么新内容？", symbol: "sparkles") {
                                state.lastMessage = "版本 1.0：完整复刻 AlDente Pro 功能集"
                            }
                            HStack {
                                Text("接收 Beta 版本更新").font(.system(size: 12))
                                Spacer()
                                Toggle("", isOn: $state.receiveBetaUpdates)
                                    .labelsHidden().toggleStyle(.switch).tint(theme.accent)
                                    .scaleEffect(0.72).frame(width: 36, height: 20)
                            }
                        }
                    }
                }

                Text("其他")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                    .padding(.leading, 4)
                    .padding(.top, 6)

                Card {
                    VStack(spacing: 4) {
                        ToggleRow(symbol: "power",
                                  title: "开机自启",
                                  help: "登录时自动启动 AIBattery。",
                                  isOn: $state.launchAtLogin)
                        Divider().background(theme.divider)
                        ToggleRow(symbol: "chart.bar.doc.horizontal",
                                  title: "共享技术数据",
                                  help: "选择加入并帮助改善 AIBattery，可随时退出。",
                                  isOn: $state.dataShareConsent)
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
                            ForEach(Array(state.capabilities.rawKeys.enumerated()), id: \.offset) { item in
                                HStack {
                                    Text(item.element.0)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.textSecondary)
                                    Spacer()
                                    Text(item.element.1)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.textPrimary)
                                }
                            }
                            if !state.helperInstalled {
                                Button {
                                    state.installHelper()
                                } label: {
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
                    Text("AIBattery 1.0.0")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                    Spacer()
                    Link("apphousekitchen.com", destination: URL(string: "https://apphousekitchen.com")!)
                        .font(.system(size: 10))
                        .foregroundColor(theme.accent)
                    Text("· 本地构建")
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
                Text("AIBattery 1.0.0").font(.system(size: 14, weight: .semibold))
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
            Circle()
                .fill(color(for: quality))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Text(source)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.textTertiary)
            Text(quality.badge)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color(for: quality))
                .frame(width: 34, alignment: .trailing)
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
            Button {
                state.colorMode = mode
            } label: {
                Circle()
                    .fill(mode == 0 ? theme.innerControl : (mode == 1 ? Color.white : Color.black))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(state.colorMode == mode ? theme.accent : theme.cardStroke, lineWidth: state.colorMode == mode ? 2 : 1))
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 8))
                            .foregroundColor(mode == 1 ? .black : .white)
                    )
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(theme.textSecondary)
        }
    }

    private func saveDebugFile() {
        let info = """
        AIBattery debug export
        date: \(Date())
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        model: \(modelIdentifier())
        strategy: \(state.capabilities.strategy.title)
        helper: \(state.helperInstalled)
        chargeVal: \(state.chargeVal)
        snapshot: \(state.snapshot)
        smc: \(state.capabilities.rawKeys.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))
        """
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIBattery-debug.txt")
        try? info.write(to: url, atomically: true, encoding: .utf8)
        state.lastMessage = "调试文件已保存到下载文件夹"
    }

    private func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
    }

    private func restoreDefaults() {
        state.chargeVal = 80
        state.sailingMode = true
        state.sailingLevel = 5
        state.automaticDischarge = true
        state.heatProtectMode = false
        state.maxTemperature = 35
        state.allowBelow80 = true
        state.selectedMenuBarItems = []
        state.menuBarSpacing = 5
        state.lastMessage = "已恢复默认设置"
    }
}

extension Notification.Name {
    static let openPopoverEditMode = Notification.Name("openPopoverEditMode")
}
