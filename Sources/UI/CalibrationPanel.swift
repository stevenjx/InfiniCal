//
//  CalibrationPanel.swift
//  Battery calibration monitoring, shown inside 「充电控制」.
//
//  Layout follows the standalone calibration tool: live pack telemetry, the
//  five-stage pipeline, health/capacity results, host thermals, two live scopes,
//  the discharge-load control and the event log. All numbers come from
//  CalibrationEngine, which measures them locally.
//

import SwiftUI
import AppKit

/// Sidebar page wrapper — 电池校准 has its own entry, right below 充电控制.
struct CalibrationPage: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            CalibrationPanel()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }
}

struct CalibrationPanel: View {
    @ObservedObject private var engine = CalibrationEngine.shared
    @ObservedObject private var fans = FanController.shared
    @StateObject private var showHistory = UIFlag()
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if let quality = engine.resultQuality {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        CardHeader(title: tf("校准质量等级：{p}", t(quality.label)),
                                   subtitle: t("质量等级基于过程证据，不代表统计概率或测量精度保证"))
                        ForEach(quality.reasons, id: \.self) { reason in
                            Text(t(reason)).font(Typography.caption)
                        }
                    }
                }
            }
            if engine.needsRecovery {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(title: t("检测到未完成的校准"))
                        if let checkpoint = engine.pendingRecovery {
                            Text((CalibrationPhase(rawValue: checkpoint.phase)?.title ?? checkpoint.phase)
                                 + " · " + checkpoint.lastSampleAt.formatted())
                                .font(Typography.caption)
                        }
                        Text(t("中断期间无法测量。继续将从预充重新测量，不拼接旧积分；不会自动启动放电。"))
                            .font(Typography.caption)
                        if let error = engine.recoveryError {
                            Text(error).foregroundColor(theme.chartOrange)
                        }
                        HStack {
                            Button(t("继续（重新测量）")) { _ = engine.restartInterruptedSession() }
                                .disabled(engine.pendingRecovery == nil)
                            Button(t("安全清理 / 重试")) { _ = engine.cleanInterruptedSession() }
                            Button(t("放弃并恢复系统控制")) { _ = engine.cleanInterruptedSession(discard: true) }
                        }
                        .font(Typography.caption)
                    }
                }
            }
            chargeGateCard
            // Kept visible after the session ends: a restore failure at the last
            // phase is exactly the thing the user must not miss.
            if let issue = engine.chargingIssue {
                Card(padding: .compact) {
                    Text(issue)
                        .font(Typography.caption)
                        .foregroundColor(theme.chartOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            dischargeHintCard
            statusCard
            pipelineCard
            HStack(alignment: .top, spacing: 10) {
                enduranceCard
                healthCard
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                hostCard(title: t("SoC 功耗"),
                         value: engine.socPowerQuality == .unavailable
                                ? "--" : String(format: "%.1f", engine.socPowerWatts),
                         unit: "W",
                         symbol: "cpu",
                         tint: theme.chartOrange,
                         progress: min(1, engine.socPowerWatts / 50),
                         note: socNote)
                hostCard(title: t("屏幕功耗"),
                         value: engine.displayPowerQuality == .unavailable
                                ? "--" : String(format: "%.1f", engine.displayPowerWatts),
                         unit: "W",
                         symbol: "display",
                         tint: theme.chartBlue,
                         progress: min(1, engine.displayPowerWatts / 8),
                         note: engine.displayPowerQuality.badge)
                hostCard(title: t("CPU 温度"),
                         value: engine.cpuTemperature > 0 ? String(format: "%.0f", engine.cpuTemperature) : "--",
                         unit: "°C",
                         symbol: "thermometer.medium",
                         tint: engine.cpuTemperature >= 85 ? .red : theme.chartOrange,
                         progress: min(1, max(0, (engine.cpuTemperature - 30) / 70)))
                fanCard
            }
            HStack(spacing: 10) {
                scopeCard(title: engine.phase == .discharging
                          ? tf("放电曲线（{p}% → {p}%）", "\(engine.dischargeStartPercentage)", "\(engine.dischargeTarget)")
                          : t("电量趋势"),
                          badge: "\(engine.percentage)",
                          badgeUnit: "%",
                          tint: theme.chartBlue,
                          domain: 0...100,
                          steps: [Double(engine.dischargeTarget), 50, 100],
                          unit: "%",
                          points: engine.dischargeCurve.isEmpty ? engine.chartPoints : engine.dischargeCurve,
                          keyPath: \.percentage)
                scopeCard(title: t("瞬时功率"),
                          badge: String(format: "%.2f", engine.batteryPower),
                          badgeUnit: "W",
                          tint: theme.chartOrange,
                          domain: 0...max(35, (engine.chartPoints.map(\.power).max() ?? 20) + 5),
                          steps: [0, max(35, (engine.chartPoints.map(\.power).max() ?? 20) + 5) / 2],
                          unit: "W",
                          points: engine.chartPoints,
                          keyPath: \.power)
            }
            .frame(height: 110)
            HStack(spacing: 10) {
                scopeCard(title: t("电压"),
                          badge: String(format: "%.2f", engine.voltage),
                          badgeUnit: "V",
                          tint: theme.chartBlue,
                          domain: voltageDomain,
                          steps: [voltageDomain.lowerBound,
                                  (voltageDomain.lowerBound + voltageDomain.upperBound) / 2,
                                  voltageDomain.upperBound],
                          unit: "V",
                          points: engine.chartPoints,
                          keyPath: \.voltage)
                scopeCard(title: t("电流"),
                          badge: String(format: "%.2f", engine.signedAmperage),
                          badgeUnit: "A",
                          tint: theme.chartOrange,
                          domain: currentDomain,
                          steps: [currentDomain.lowerBound, 0, currentDomain.upperBound],
                          unit: "A",
                          points: engine.chartPoints,
                          keyPath: \.amperage)
                scopeCard(title: t("温度"),
                          badge: String(format: "%.1f", engine.temperature),
                          badgeUnit: "°C",
                          tint: theme.chartGreen,
                          domain: temperatureDomain,
                          steps: [temperatureDomain.lowerBound,
                                  (temperatureDomain.lowerBound + temperatureDomain.upperBound) / 2,
                                  temperatureDomain.upperBound],
                          unit: "°C",
                          points: engine.chartPoints,
                          keyPath: \.temperature)
            }
            .frame(height: 110)
            if engine.cellVoltages.count >= 2 {
                HStack(spacing: 10) {
                    scopeCard(title: t("电芯压差"),
                              badge: String(format: "%.1f", engine.cellDeltaMillivolts),
                              badgeUnit: "mV",
                              tint: theme.chartOrange,
                              domain: 0...cellDeltaCeiling,
                              steps: [0, cellDeltaCeiling / 2],
                              unit: "mV",
                              points: engine.chartPoints,
                              keyPath: \.cellDeltaMillivolts)
                    cellBalanceCard
                }
                .frame(height: 110)
            }
            controlBar
            Card {
                CardHeader(title: t("报告与数据导出")) {
                    HStack(spacing: Spacing.s) {
                        ForEach(["txt", "csv", "json"], id: \.self) { format in
                            Button(format.uppercased()) { engine.exportSession(format: format) }
                                .disabled(!engine.hasExportSamples)
                        }
                    }
                }
            }
        }
        .onAppear {
            engine.beginTelemetryPage()
            // Keep the shared fan sampler running so this page reports exactly the
            // same numbers as 风扇控制.
            FanController.shared.beginMonitoring()
        }
        .onDisappear {
            engine.endTelemetryPage()
            FanController.shared.endMonitoring()
        }
        .sheet(isPresented: $showHistory.value) {
            CalibrationHistorySheet(engine: engine, isPresented: $showHistory.value)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "wrench.and.screwdriver")
            Text(t("电池校准"))
                .font(Typography.title)
                .foregroundColor(theme.textPrimary)
            HelpDot(text: t("完整走一遍 满充 → 受控放电 → 复充 → 静置 → 回落 的循环，用库仑积分算出电池真实的满充容量与健康度。全过程本地完成，不依赖任何第三方 App。"))
            if let last = engine.lastCalibrationDate {
                Text(tf("上次校准 {p}", Self.lastRun.string(from: last)))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
            Spacer()
            if engine.phase != .idle { statusPill }
            Button {
                AppState.shared.requestCalibrationStart()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(Glyph.inline)
                    Text(engine.isRunning ? t("停止校准") : t("开始校准"))
                        .font(Typography.headline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(engine.isRunning ? Color.red.opacity(0.18) : theme.accent))
                .foregroundColor(engine.isRunning ? Color.red : Color.white)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 34)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Image(systemName: engine.phase.symbol)
                .font(Glyph.inline.weight(.bold))
            Text(engine.phase.title)
                .font(Typography.label)
        }
        .foregroundColor(phaseTint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(phaseTint.opacity(theme.isDark ? 0.18 : 0.12)))
    }

    private var phaseTint: Color {
        switch engine.phase {
        case .idle: return theme.textSecondary
        case .chargingToFull, .rechargingToFull: return theme.chartBlue
        case .discharging, .dischargingToBuffer: return theme.chartOrange
        case .holdingAtFull: return theme.chartPurple
        case .completed: return theme.chartGreen
        }
    }

    // MARK: - Charging precondition

    /// Shown when the discharge phase is sitting on adapter power. Intel
    /// machines expose only a charge inhibit (CH0B/CH0C), which stops charging
    /// but leaves the Mac running from the adapter at 0.00 A, so the phase can
    /// never finish until the cable comes out.
    @ViewBuilder
    private var dischargeHintCard: some View {
        if engine.needsUnplugForDischarge, engine.isRunning {
            Card {
                HStack(spacing: 9) {
                    Image(systemName: "powerplug.fill")
                        .font(Glyph.row.weight(.semibold))
                        .foregroundColor(theme.chartOrange)
                    Text(t("放电指令已下发，但 60 秒内仍未测到放电电流。放电指令保持生效，也可以拔掉电源适配器让它立即开始。"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Shown only while the system is holding the pack below full and the user
    /// has not confirmed they cleared it. macOS exposes no flag for
    /// 「优化电池充电」 / 「充电上限」, so the copy names the symptom first and
    /// the likely causes second instead of asserting one.
    @ViewBuilder
    private var chargeGateCard: some View {
        if engine.isChargeHeld, !engine.isRunning {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: tf("系统正在限制充电（当前 {p}%），校准可能充不到满电",
                                         "\(engine.percentage)"),
                               symbol: "exclamationmark.triangle.fill", tint: theme.chartOrange)

                    Text(t("「优化电池充电」会在 80% 附近暂停充电，新版 macOS 的「充电上限」也会把电量锁在设定值；适配器功率不足或温度过高同样会暂停。校准需要连续充到满电，请先按以下步骤关闭。若设置里已经是 100% 仍不充电，拔插一次电源后再点「刷新状态」："))
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 3) {
                        stepLine(1, t("打开「系统设置」→「电池」"))
                        stepLine(2, t("点按「电池健康」右侧的 ⓘ"))
                        stepLine(3, t("关闭「优化电池充电」，并把充电上限调到 100%"))
                    }

                    HStack(spacing: 8) {
                        SmallActionButton(title: t("打开系统设置"), symbol: "gearshape") {
                            openBatterySettings()
                        }
                        SmallActionButton(title: t("刷新状态"), symbol: "arrow.clockwise") {
                            engine.refreshChargeHold()
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func stepLine(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(index).")
                .font(Typography.label.weight(.semibold).monospacedDigit())
                .foregroundColor(theme.textTertiary)
            Text(text)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Verified on this machine: `com.apple.Battery-Settings.extension` is the
    /// bundle id of `/System/Library/ExtensionKit/Extensions/PowerPreferences.appex`.
    /// That pane only exists from Ventura, so Monterey falls back to the legacy
    /// preference pane.
    private func openBatterySettings() {
        if #available(macOS 13.0, *),
           let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Battery.prefPane"))
    }

    // MARK: - Live status

    private var statusCard: some View {
        Card {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    CalibrationRing(percentage: engine.percentage,
                                    isCharging: engine.isCharging,
                                    isDischarging: engine.signedAmperage < -0.05,
                                    accent: theme.chartBlue)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(engine.percentage)")
                                .font(Typography.display.weight(.bold))
                                .foregroundColor(theme.textPrimary)
                                .monospacedDigit()
                            Text("%")
                                .font(Typography.label.weight(.semibold))
                                .foregroundColor(theme.textSecondary)
                        }
                        Text(powerStateText)
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(engine.isExternalConnected ? theme.chartGreen : theme.textTertiary)
                                .frame(width: 5, height: 5)
                            Text(tf("设计 {p} mAh · 系统满充容量 {p} mAh", "\(Int(engine.designCapacityMAh))", "\(Int(engine.rawMaxCapacityMAh))"))
                                .font(Typography.micro)
                                .foregroundColor(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(minWidth: 132, alignment: .leading)
                }

                Rectangle().fill(theme.divider).frame(width: 1, height: 48)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          alignment: .leading, spacing: 9) {
                    metric(t("电压"), String(format: "%.2f", engine.voltage), "V", "bolt", theme.textPrimary)
                    metric(t("电流"), String(format: "%.2f", engine.signedAmperage), "A",
                           "arrow.left.arrow.right", amperageTint)
                    metric(t("电池功率"), String(format: "%.2f", engine.batteryPower), "W", "power", theme.chartOrange)
                    metric(t("电池温度"),
                           engine.temperature > 0 ? String(format: "%.1f", engine.temperature) : "--",
                           "°C", "thermometer.medium",
                           engine.temperature >= engine.highTemperature ? .red : theme.textPrimary)
                    metric(t("剩余容量"), String(format: "%.0f", engine.remainingCapacityMAh), "mAh", "battery.50", theme.textPrimary)
                    metric(t("循环次数"), "\(engine.cycleCount)", "", "arrow.triangle.2.circlepath", theme.textPrimary)
                }
            }
        }
    }

    private var powerStateText: String {
        if engine.isDischargingOnAC { return t("正在放电（接电但已阻断充电）") }
        if engine.isCharging { return t("正在充电") }
        if engine.isExternalConnected { return t("已连接电源，未充电") }
        return t("正在使用电池")
    }

    private var amperageTint: Color {
        if engine.signedAmperage < -0.05 { return theme.chartOrange }
        if engine.signedAmperage > 0.05 { return theme.chartGreen }
        return theme.textPrimary
    }

    private func metric(_ title: String, _ value: String, _ unit: String,
                        _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(Glyph.inline.weight(.semibold))
                    .foregroundColor(theme.textTertiary)
                Text(title)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typography.headline)
                    .foregroundColor(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(Typography.micro)
                    .foregroundColor(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pipeline

    private var steps: [CalibrationPhase] {
        [.chargingToFull, .discharging, .rechargingToFull, .holdingAtFull, .dischargingToBuffer]
    }

    private var currentIndex: Int {
        switch engine.phase {
        case .idle: return -1
        case .chargingToFull: return 0
        case .discharging: return 1
        case .rechargingToFull: return 2
        case .holdingAtFull: return 3
        case .dischargingToBuffer: return 4
        case .completed: return 5
        }
    }

    private var pipelineCard: some View {
        Card(padding: .compact) {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(title: t("校准流程"), symbol: "arrow.triangle.branch",
                           tint: theme.textSecondary) {
                    Text(pipelineProgressText)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                }

                HStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { item in
                        pipelineStep(index: item.offset, phase: item.element)
                        if item.offset < steps.count - 1 {
                            Rectangle()
                                .fill(currentIndex > item.offset ? theme.accent.opacity(0.55) : theme.divider)
                                .frame(width: 18, height: 1.5)
                                .offset(y: -11)
                        }
                    }
                }
            }
        }
    }

    private var pipelineProgressText: String {
        if currentIndex < 0 { return t("尚未开始") }
        if currentIndex >= steps.count { return t("已完成") }
        return tf("第 {p} / {p} 步", "\(currentIndex + 1)", "\(steps.count)")
    }

    private func pipelineStep(index: Int, phase: CalibrationPhase) -> some View {
        let isActive = currentIndex == index
        let isDone = currentIndex > index
        let tint = isActive ? theme.accent : (isDone ? theme.accent.opacity(0.75) : theme.textTertiary)

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint.opacity(theme.isDark
                                        ? (isActive ? 0.18 : (isDone ? 0.10 : 0.06))
                                        : (isActive ? 0.26 : (isDone ? 0.16 : 0.11))))
                    .frame(width: 32, height: 32)
                Circle()
                    .strokeBorder(tint.opacity(isActive ? 0.85 : (theme.isDark ? 0.25 : 0.45)),
                                  lineWidth: isActive ? 1.4 : 1)
                    .frame(width: 32, height: 32)
                Image(systemName: phase.symbol)
                    .font(Glyph.row.weight(.semibold))
                    .foregroundColor(tint)
            }
            Text(stepTitle(phase))
                .font(Typography.micro.weight(isActive ? .bold : .regular))
                .foregroundColor(isActive ? theme.textPrimary : theme.textSecondary)
                .multilineTextAlignment(.center)
                // Two lines at micro: a fixed 24 pt frame clipped the second
                // line once the label moved up from 9.5 pt.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 24, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepTitle(_ phase: CalibrationPhase) -> String {
        switch phase {
        case .chargingToFull: return t("预充至\n100%")
        case .discharging: return tf("受控放电\n至 {p}%", "\(engine.dischargeTarget)")
        case .rechargingToFull: return t("复充至\n100%")
        case .holdingAtFull: return t("满电静置\n10 分钟")
        case .dischargingToBuffer: return tf("回落至\n{p}%", "\(engine.storageLevel)")
        default: return phase.title
        }
    }

    // MARK: - Results

    private var enduranceCard: some View {
        Card(padding: .compact) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: t("续航评估"), symbol: "clock", tint: theme.chartOrange) {
                    if engine.aiRemainingMinutes > 0 {
                        Text(t("AI 预测"))
                            .font(Typography.micro.weight(.semibold))
                            .foregroundColor(theme.chartPurple)
                    }
                }

                let minutes = engine.aiRemainingMinutes > 0 ? engine.aiRemainingMinutes : engine.estimatedRemainingMinutes
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Self.duration(minutes))
                        .font(Typography.figure.weight(.bold))
                        .foregroundColor(minutes > 0 ? theme.chartOrange : theme.textSecondary)
                        .monospacedDigit()
                    Text(t("预计可用"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    metric(t("全周期耗时"), Self.duration(engine.totalDischargeRuntimeMinutes), "", "hourglass", theme.textPrimary)
                    metric(t("平均放电功耗"), String(format: "%.1f", engine.dischargeAveragePower), "W", "bolt.slash", theme.textPrimary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var healthCard: some View {
        Card(padding: .compact) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: t("健康度与容量"), symbol: "heart", tint: theme.chartBlue) {
                    if engine.aiConfidence > 0 {
                        Text(tf("置信度 {p}%", "\(Int(engine.aiConfidence))"))
                            .font(Typography.micro)
                            .foregroundColor(theme.textSecondary)
                    }
                }

                let health = engine.measuredHealth > 0 ? engine.measuredHealth : engine.aiTrueHealthPercent
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(health > 0 ? String(format: "%.1f", health) : "--")
                        .font(Typography.figure.weight(.bold))
                        .foregroundColor(health >= 80 ? theme.chartGreen : (health > 0 ? theme.chartOrange : theme.textSecondary))
                        .monospacedDigit()
                    if health > 0 {
                        Text("%")
                            .font(Typography.label.weight(.semibold))
                            .foregroundColor(theme.textSecondary)
                    }
                    Text(t("电池健康度"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    metric(t("真实满充容量"),
                           engine.aiTrueCapacityMAh > 0 ? String(format: "%.0f", engine.aiTrueCapacityMAh) : "--",
                           "mAh", "battery.100", theme.textPrimary)
                    metric(t("直流内阻"),
                           engine.internalResistanceMilliohm > 0 ? String(format: "%.1f", engine.internalResistanceMilliohm) : "--",
                           "mΩ", "waveform.path.ecg", theme.textPrimary)
                }

                if !engine.cellVoltages.isEmpty {
                    Text(tf("电芯 {p} V · 压差 {p} mV", engine.cellVoltages.map { String(format: "%.3f", $0) }.joined(separator: " / "), String(format: "%.1f", engine.cellDeltaMillivolts)))
                        .font(Typography.micro.monospaced())
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }

                trendLine
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Straight-line decay from the daily history, or an honest "not enough
    /// data yet" — never a guessed number.
    @ViewBuilder
    private var trendLine: some View {
        if let trend = engine.trend {
            HStack(spacing: 5) {
                Image(systemName: trend.isAccelerating ? "arrow.down.right" : "arrow.down.forward")
                    .font(Glyph.inline.weight(.bold))
                    .foregroundColor(trend.isAccelerating ? theme.chartOrange : theme.textTertiary)
                Text(tf("衰减 {p} ± {p} %/100 次循环 · {p} 个样本",
                        String(format: "%.2f", trend.slopePer100Cycles),
                        String(format: "%.2f", trend.slopeMargin),
                        "\(trend.sampleCount)"))
                    .font(Typography.micro)
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
                if let cycles = trend.cyclesToThreshold, cycles > 0 {
                    Text(tf("· 约 {p} 次循环后降至 {p}%", "\(cycles)", "\(Int(trend.threshold))"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            Text(t("衰减趋势: 样本不足（至少 8 个不同循环数、跨度 20 次），继续使用后可推算"))
                .font(Typography.micro)
                .foregroundColor(theme.textTertiary)
                .lineLimit(1)
        }
    }

    /// Quality badge, plus the CPU/GPU split when powermetrics produced one.
    private var socNote: String {
        guard engine.socPowerQuality == .measured, engine.socCPUWatts > 0 else {
            return engine.socPowerQuality.badge
        }
        return tf("{p} · CPU {p} · GPU {p}", engine.socPowerQuality.badge,
                  String(format: "%.1f", engine.socCPUWatts),
                  String(format: "%.1f", engine.socGPUWatts))
    }

    // MARK: - Host telemetry

    private func hostCard(title: String, value: String, unit: String,
                          symbol: String, tint: Color, progress: Double,
                          note: String? = nil) -> some View {
        Card(padding: .compact) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(tint.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.04, min(1, progress))))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: symbol)
                        .font(Glyph.inline.weight(.semibold))
                        .foregroundColor(tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(Typography.headline.weight(.bold))
                            .foregroundColor(theme.textPrimary)
                            .monospacedDigit()
                        Text(unit)
                            .font(Typography.micro)
                            .foregroundColor(theme.textSecondary)
                    }
                    if let note {
                        Text(note)
                            .font(Typography.micro)
                            .foregroundColor(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var fanCard: some View {
        // Read the same published sample the 风扇控制 page shows, so the two
        // pages can never display different numbers for the same instant.
        let readings = fans.fans
        let current = readings.map { $0.currentRPM }.max() ?? 0
        let ceiling = readings.map { $0.maxRPM }.max() ?? 0
        let hasFan = !readings.isEmpty

        return Card(padding: .compact) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(theme.chartPurple.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(ceiling > 0 ? min(1, Double(current) / Double(ceiling)) : 0))
                        .stroke(theme.chartPurple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "fanblades.fill")
                        .font(Glyph.row.weight(.semibold))
                        .foregroundColor(hasFan ? theme.chartPurple : theme.textTertiary)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(t("风扇转速"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(hasFan ? "\(current)" : "--")
                            .font(Typography.headline.weight(.bold))
                            .foregroundColor(hasFan ? theme.textPrimary : theme.textSecondary)
                            .monospacedDigit()
                        Text("RPM")
                            .font(Typography.micro)
                            .foregroundColor(theme.textSecondary)
                    }
                    Text(hasFan
                         ? (current > 0 ? tf("最高 · {p} 个风扇", "\(readings.count)") : t("已停转（正常待机）"))
                         : t("此机型无风扇"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Scopes

    // MARK: - Chart domains

    /// Prefer the discharge window when there is one: it is the slice the
    /// measurement is taken from, so the axes stay comparable between runs.
    private var livePoints: [CalibrationSample] {
        engine.dischargeCurve.isEmpty ? engine.chartPoints : engine.dischargeCurve
    }

    private var voltageDomain: ClosedRange<Double> {
        let values = livePoints.map(\.voltage).filter { $0 > 0 }
        let low = values.min() ?? 10
        let high = values.max() ?? 13
        let pad = max(0.3, (high - low) * 0.15)
        return max(0, low - pad)...max(low + pad, high + pad)
    }

    /// Signed: discharge is negative, so the zero line has to be visible for
    /// the sign of the current to mean anything.
    private var currentDomain: ClosedRange<Double> {
        let peak = max(1, livePoints.map { abs($0.amperage) }.max() ?? 1)
        let bound = peak * 1.2
        return -bound...bound
    }

    private var temperatureDomain: ClosedRange<Double> {
        let values = livePoints.map(\.temperature).filter { $0 > 0 }
        let low = values.min() ?? 20
        let high = values.max() ?? 40
        return max(0, low - 3)...max(low + 5, high + 3)
    }

    private var cellDeltaCeiling: Double {
        let peak = livePoints.map(\.cellDeltaMillivolts).max() ?? 0
        return max(30, (peak * 1.3).rounded(.up))
    }

    /// Per-cell voltages as thin bars, so an outlier is visible at a glance
    /// rather than only as a single spread number.
    private var cellBalanceCard: some View {
        let cells = engine.cellVoltages
        let low = cells.min() ?? 0
        let high = cells.max() ?? 1
        let span = max(0.001, high - low)
        return Card(padding: .compact) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(theme.chartGreen).frame(width: 5, height: 5)
                    Text(t("电芯电压"))
                        .font(Typography.label.weight(.semibold))
                        .foregroundColor(theme.textPrimary)
                    Spacer(minLength: 6)
                    Text(tf("压差 {p} mV", String(format: "%.1f", engine.cellDeltaMillivolts)))
                        .font(Typography.micro.monospaced())
                        .foregroundColor(theme.textSecondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { index, volts in
                    HStack(spacing: 6) {
                        Text("C\(index + 1)")
                            .font(Typography.micro.monospaced())
                            .foregroundColor(theme.textTertiary)
                            .frame(width: 18, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.innerControl)
                                Capsule()
                                    .fill(theme.chartGreen.opacity(0.85))
                                    .frame(width: max(2, geo.size.width * CGFloat((volts - low) / span)))
                            }
                        }
                        .frame(height: 4)
                        Text(String(format: "%.3f", volts))
                            .font(Typography.micro.monospaced())
                            .foregroundColor(theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scopeCard(title: String, badge: String, badgeUnit: String, tint: Color,
                           domain: ClosedRange<Double>, steps: [Double], unit: String,
                           points: [CalibrationSample],
                           keyPath: KeyPath<CalibrationSample, Double>) -> some View {
        Card(padding: .compact) {
            CalibrationScopeCard(title: title, badge: badge, badgeUnit: badgeUnit, tint: tint,
                                 domain: domain, steps: steps, unit: unit,
                                 points: points, keyPath: keyPath)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(Glyph.inline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)
                Text(t("放电负载"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize()
                Picker("", selection: Binding(get: { engine.stressMode },
                                              set: { engine.stressMode = $0 })) {
                    ForEach(DischargeStressMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: L10n.isChinese ? 100 : 140)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.innerControl))

            HStack(spacing: 6) {
                Text(t("放电至"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Picker("", selection: Binding(get: { engine.dischargeTarget },
                                              set: { engine.dischargeTarget = $0 })) {
                    Text(t("5%（深度）")).tag(5)
                    Text(t("10%（推荐）")).tag(10)
                    Text(t("15%（温和）")).tag(15)
                    Text(t("20%（快速）")).tag(20)
                }
                .labelsHidden()
                .frame(width: 118)
            }

            HStack(spacing: 6) {
                Text(t("温度保护"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Picker("", selection: Binding(get: { Int(engine.highTemperature) },
                                              set: {
                                                  engine.highTemperature = Double($0)
                                                  engine.resumeTemperature = Double($0 - 6)
                                              })) {
                    ForEach(Array(stride(from: 40, through: 55, by: 1)), id: \.self) { value in
                        Text("\(value)°C").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 74)
            }

            Spacer(minLength: 8)

            if engine.isGPUStressActive {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.horizontal.circle.fill").font(Glyph.inline.weight(.bold))
                    Text(t("GPU 加压中")).font(Typography.micro)
                }
                .foregroundColor(theme.chartOrange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(theme.chartOrange.opacity(0.14)))
            }

            if engine.isThermalCutoffActive {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.sun.fill").font(Glyph.inline.weight(.bold))
                    Text(t("温度保护中")).font(Typography.micro)
                }
                .foregroundColor(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.red.opacity(0.14)))
            }

            SmallActionButton(title: t("历史记录"), symbol: "clock.arrow.circlepath") {
                showHistory.value = true
            }
            .frame(width: 100)
        }
    }

    static func duration(_ minutes: Int) -> String {
        guard minutes > 0 else { return "--" }
        if minutes < 60 { return tf("{p} 分钟", "\(minutes)") }
        return tf("{p} 小时 {p} 分", "\(minutes / 60)", "\(minutes % 60)")
    }

    static let lastRun: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()
}

// MARK: - State of charge ring

private struct CalibrationRing: View {
    let percentage: Int
    let isCharging: Bool
    let isDischarging: Bool
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.01, min(1, Double(percentage) / 100))))
                .stroke(LinearGradient(colors: ringColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: isCharging ? "bolt.fill" : (isDischarging ? "flame.fill" : "leaf.fill"))
                .font(Glyph.row.weight(.semibold))
                .foregroundColor(isCharging ? .green : (isDischarging ? .orange : accent))
        }
        .frame(width: 54, height: 54)
    }

    private var ringColors: [Color] {
        if percentage <= 20 { return [.red, .orange] }
        if isCharging { return [.green, .mint] }
        return [accent, accent.opacity(0.55)]
    }
}

// MARK: - Live scope

private struct CalibrationScopeCard: View {
    private var theme: Theme { Theme.current }
    let title: String
    let badge: String
    let badgeUnit: String
    let tint: Color
    let domain: ClosedRange<Double>
    let steps: [Double]
    let unit: String
    let points: [CalibrationSample]
    let keyPath: KeyPath<CalibrationSample, Double>

    @StateObject private var probe = UIValue<CalibrationSample?>(nil)
    @StateObject private var probeX = UIValue<CGFloat?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(title)
                    .font(Typography.label.weight(.semibold))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let selected = probe.value {
                    HStack(spacing: 5) {
                        Text(Self.time.string(from: selected.timestamp))
                            .font(Typography.micro.monospaced())
                            .foregroundColor(theme.textSecondary)
                        Text("\(String(format: "%.1f", selected[keyPath: keyPath])) \(unit)")
                            .font(Typography.micro.weight(.semibold).monospaced())
                            .foregroundColor(tint)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(badge)
                            .font(Typography.label.weight(.bold).monospaced())
                            .foregroundColor(tint)
                        Text(badgeUnit)
                            .font(Typography.micro)
                            .foregroundColor(theme.textSecondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(theme.isDark ? 0.18 : 0.11)))
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    CalibrationScopeChart(points: points, keyPath: keyPath, tint: tint,
                                          domain: domain, steps: steps, unit: unit,
                                          isDark: theme.isDark,
                                          probe: probe.value)
                        .overlay(
                            CalibrationPointerView(
                                onMove: { location in updateProbe(location, size: geometry.size) },
                                onEnd: {
                                    probe.value = nil
                                    probeX.value = nil
                                }
                            )
                        )

                    if let selected = probe.value, let x = probeX.value {
                        Text("\(Self.time.string(from: selected.timestamp)) · \(String(format: "%.1f", selected[keyPath: keyPath]))\(unit)")
                            .font(Typography.micro.weight(.semibold).monospaced())
                            .foregroundColor(theme.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(theme.cardElevated))
                            .offset(x: min(max(x - 40, 30), max(30, geometry.size.width - 120)), y: 0)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func updateProbe(_ location: CGPoint, size: CGSize) {
        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        let plotWidth = CalibrationScopeLayout.plotWidth(size.width)
        guard plotWidth > 1 else { return }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0.001 else { return }

        let ratio = min(1, max(0, Double((location.x - CalibrationScopeLayout.leadingInset) / plotWidth)))
        let target = first.timestamp.addingTimeInterval(span * ratio)
        guard let nearest = points.min(by: {
            abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target))
        }) else { return }
        probe.value = nearest
        probeX.value = location.x
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private enum CalibrationScopeLayout {
    static let leadingInset: CGFloat = 32
    static let bottomInset: CGFloat = 18
    static let topInset: CGFloat = 6
    static let trailingInset: CGFloat = 4

    static func plotWidth(_ width: CGFloat) -> CGFloat {
        max(1, width - leadingInset - trailingInset)
    }

    static func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: leadingInset, y: topInset,
               width: plotWidth(size.width),
               height: max(1, size.height - topInset - bottomInset))
    }
}

private struct CalibrationScopeChart: View {
    let points: [CalibrationSample]
    let keyPath: KeyPath<CalibrationSample, Double>
    let tint: Color
    let domain: ClosedRange<Double>
    let steps: [Double]
    let unit: String
    let isDark: Bool
    let probe: CalibrationSample?

    var body: some View {
        Canvas { context, size in
            draw(context: &context, size: size)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let plot = CalibrationScopeLayout.plotRect(size)
        guard plot.width > 2, plot.height > 2 else { return }

        let lower = domain.lowerBound
        let upper = max(domain.upperBound, lower + 0.0001)

        func y(_ value: Double) -> CGFloat {
            let clamped = min(upper, max(lower, value))
            return plot.maxY - CGFloat((clamped - lower) / (upper - lower)) * plot.height
        }

        drawGrid(context: &context, plot: plot, y: y)

        guard let first = points.first, let last = points.last else { return }
        let span = last.timestamp.timeIntervalSince(first.timestamp)

        func x(_ date: Date) -> CGFloat {
            guard span > 0.001 else { return plot.minX }
            let ratio = date.timeIntervalSince(first.timestamp) / span
            return plot.minX + CGFloat(min(1, max(0, ratio))) * plot.width
        }

        drawTimeAxis(context: &context, plot: plot, first: first, span: span)

        var line = Path()
        for (index, point) in points.enumerated() {
            let pointX = x(point.timestamp)
            let pointY = y(point[keyPath: keyPath])
            if index == 0 { line.move(to: CGPoint(x: pointX, y: pointY)) }
            else { line.addLine(to: CGPoint(x: pointX, y: pointY)) }
        }

        if points.count >= 2 {
            var area = line
            area.addLine(to: CGPoint(x: x(last.timestamp), y: plot.maxY))
            area.addLine(to: CGPoint(x: x(first.timestamp), y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(isDark ? 0.24 : 0.16), tint.opacity(0.012)]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }

        if let probe {
            let px = x(probe.timestamp)
            var rule = Path()
            rule.move(to: CGPoint(x: px, y: plot.minY))
            rule.addLine(to: CGPoint(x: px, y: plot.maxY))
            context.stroke(rule, with: .color(Color.primary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let py = y(probe[keyPath: keyPath])
            context.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7)),
                         with: .color(tint))
        } else if let lastPoint = points.last {
            let px = x(lastPoint.timestamp)
            let py = y(lastPoint[keyPath: keyPath])
            context.fill(Path(ellipseIn: CGRect(x: px - 4.5, y: py - 4.5, width: 9, height: 9)),
                         with: .color(tint.opacity(0.2)))
            context.fill(Path(ellipseIn: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)),
                         with: .color(tint))
        }
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect, y: (Double) -> CGFloat) {
        let gridColor = Color.primary.opacity(isDark ? 0.10 : 0.07)

        for step in steps {
            let position = y(step)
            guard position >= plot.minY - 0.5, position <= plot.maxY + 0.5 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: position))
            line.addLine(to: CGPoint(x: plot.maxX, y: position))
            context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            let label = Text(String(format: "%.0f%@", step, unit))
                .font(Typography.micro.monospaced())
                .foregroundColor(Color.secondary)
            context.draw(label, at: CGPoint(x: plot.minX - 5, y: position), anchor: .trailing)
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(baseline, with: .color(Color.primary.opacity(0.10)), style: StrokeStyle(lineWidth: 0.6))
    }

    private func drawTimeAxis(context: inout GraphicsContext, plot: CGRect, first: CalibrationSample, span: TimeInterval) {
        guard span > 1 else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = span < 180 ? "HH:mm:ss" : "HH:mm"

        let tickCount = max(2, min(4, Int(plot.width / 110)))
        for index in 0..<tickCount {
            let ratio = CGFloat(index) / CGFloat(tickCount - 1)
            let position = plot.minX + ratio * plot.width
            let date = first.timestamp.addingTimeInterval(span * Double(ratio))
            let anchor: UnitPoint = index == 0 ? .topLeading : (index == tickCount - 1 ? .topTrailing : .top)
            let label = Text(formatter.string(from: date))
                .font(Typography.micro.monospaced())
                .foregroundColor(Color.secondary)
            context.draw(label, at: CGPoint(x: position, y: plot.maxY + 4), anchor: anchor)
        }
    }
}

// MARK: - Pointer tracking (macOS 12 has no onContinuousHover)

private struct CalibrationPointerView: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> CalibrationPointerNSView {
        let view = CalibrationPointerNSView()
        view.onMove = onMove
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: CalibrationPointerNSView, context: Context) {
        view.onMove = onMove
        view.onEnd = onEnd
    }
}

private final class CalibrationPointerNSView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func report(_ event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onEnd?() }
}

// MARK: - History sheet

/// The session log, shown inside 历史记录 next to the saved records.
private struct CalibrationLogView: View {
    @ObservedObject var engine: CalibrationEngine
    @StateObject private var follow = UIFlag(true)
    @StateObject private var exportError = UIValue<String?>(nil)
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(t("保留本次运行最近 800 条记录"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                Spacer(minLength: 8)
                Toggle(t("跟随最新"), isOn: $follow.value)
                    .toggleStyle(.checkbox)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Button(t("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportText, forType: .string)
                }
                Button(t("导出")) { export() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    Text(engine.log.isEmpty ? t("暂无日志，开始校准后将在此显示。") : engine.log.joined(separator: "\n"))
                        .font(Typography.caption.monospaced())
                        .foregroundColor(theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("log-end")
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.innerControl.opacity(0.45))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .onAppear { if follow.value { reader.scrollTo("log-end", anchor: .bottom) } }
                .onChange(of: engine.log.last) { _ in
                    if follow.value { reader.scrollTo("log-end", anchor: .bottom) }
                }
            }

            if let error = exportError.value {
                Text(error)
                    .font(Typography.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private var exportText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "InfiniCal \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            + "Phase: \(engine.phase.rawValue)\n"
            + String(format: "Battery: %d%%, %+.3f A, %.3f V\n", engine.percentage, engine.signedAmperage, engine.voltage)
            + engine.log.joined(separator: "\n") + "\n"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InfiniCal_Calibration_Log.txt"
        panel.canCreateDirectories = true
        let text = exportText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                exportError.value = nil
            } catch {
                exportError.value = error.localizedDescription
            }
        }
    }
}

private struct CalibrationHistorySheet: View {
    @ObservedObject var engine: CalibrationEngine
    @Binding var isPresented: Bool
    @StateObject private var tab = UIValue<Int>(0)
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(theme.accent)
                Text(t("历史校准记录"))
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                if !engine.records.isEmpty, tab.value == 0 {
                    Button(t("清空")) { engine.clearHistory() }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        .font(Typography.body)
                }
                Button(t("完成")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider().background(theme.divider)

            Picker("", selection: $tab.value) {
                Text(t("校准记录")).tag(0)
                Text(t("运行日志")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if tab.value == 1 {
                CalibrationLogView(engine: engine)
            } else {
                recordsContent
            }
        }
        .frame(width: 620, height: 580)
        .background(theme.windowBackground)
    }

    @ViewBuilder
    private var recordsContent: some View {
        if engine.records.count >= 2 {
            trendBlock
                .padding(.horizontal, 14)
                .padding(.top, 12)
        }

        if engine.records.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "archivebox")
                    .font(Glyph.hero)
                    .foregroundColor(theme.textTertiary)
                Text(t("还没有校准记录"))
                    .font(Typography.body)
                    .foregroundColor(theme.textSecondary)
                Text(t("完成一次校准后，结果会自动保存在这里"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(engine.records) { record in
                        recordRow(record)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Trend
    //
    // Sort by date instead of trusting the stored order: the charts read left to
    // right, and the headline number has to be the newest session.

    private var chronological: [CalibrationRecord] {
        engine.records.sorted { $0.startDate < $1.startDate }
    }

    private var latestRecord: CalibrationRecord? { chronological.last }

    private var trendBlock: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                MiniChart(title: t("健康度"),
                          valueText: String(format: "%.1f%%", latestRecord?.batteryHealthPercentage ?? 0),
                          symbol: "heart",
                          color: theme.chartOrange,
                          points: chronological.map {
                              HistoryPoint(date: $0.startDate, value: $0.batteryHealthPercentage)
                          })
                MiniChart(title: t("实测容量"),
                          valueText: "\(Int(latestRecord?.calculatedCapacityMAh ?? 0)) mAh",
                          symbol: "battery.100",
                          color: theme.chartGreen,
                          points: chronological.map {
                              HistoryPoint(date: $0.startDate, value: $0.calculatedCapacityMAh)
                          })
                if dcirPoints.count >= 2 {
                    MiniChart(title: t("直流内阻"),
                              valueText: String(format: "%.1f mΩ", latestRecord?.internalResistanceMilliohm ?? 0),
                              symbol: "bolt.horizontal",
                              color: theme.chartBlue,
                              points: dcirPoints)
                }
            }
        }
    }

    private var dcirPoints: [HistoryPoint] {
        chronological
            .filter { $0.internalResistanceMilliohm > 0 }
            .map { HistoryPoint(date: $0.startDate, value: $0.internalResistanceMilliohm) }
    }

    private func recordRow(_ record: CalibrationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.date.string(from: record.startDate))
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text(String(format: "SOH %.1f%%", record.batteryHealthPercentage))
                    .font(Typography.micro.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill((record.batteryHealthPercentage >= 80 ? Color.green : Color.orange).opacity(0.14)))
                    .foregroundColor(record.batteryHealthPercentage >= 80 ? .green : .orange)
                Button {
                    engine.deleteRecord(record)
                } label: {
                    Image(systemName: "trash")
                        .font(Glyph.row)
                        .foregroundColor(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Text(tf("校准质量等级：{p}", record.quality.map { t($0.label) } ?? t("未评估（旧记录）")))
                .font(Typography.caption).foregroundColor(theme.textSecondary)
            if let quality = record.quality, !quality.reasons.isEmpty {
                Text(quality.reasons.map { t($0) }.joined(separator: "; "))
                    .font(Typography.caption).foregroundColor(theme.textSecondary)
            }
            HStack(spacing: 14) {
                value(t("实测容量"), "\(Int(record.calculatedCapacityMAh)) mAh")
                value(t("放电能量"), String(format: "%.2f Wh", record.dischargeEnergyWh))
                value(t("设计容量"), "\(Int(record.designCapacityMAh)) mAh")
                value(t("库仑效率"), String(format: "%.1f%%", record.coulombicEfficiency))
                value(t("循环"), "\(record.cycleCount)")
                if record.internalResistanceMilliohm > 0 {
                    value("DCIR", String(format: "%.1f mΩ", record.internalResistanceMilliohm))
                }
            }
            // Measurement context: a capacity figure is only comparable with
            // another one taken at a similar temperature and load.
            if let conditions = record.conditions {
                HStack(spacing: 14) {
                    if conditions.meanTemperature > 0 {
                        value(t("平均温度"), String(format: "%.1f °C", conditions.meanTemperature))
                    }
                    if conditions.meanPower > 0 {
                        value(t("平均放电功率"), String(format: "%.1f W", conditions.meanPower))
                    }
                    value(t("起始电量"), "\(conditions.startPercentage)%")
                    if let preset = conditions.preset,
                       let name = CalibrationPreset(rawValue: preset)?.title {
                        value(t("校准深度"), name)
                    }
                }
                .padding(.top, 2)
            }

            if let report = record.reportFilePath, FileManager.default.fileExists(atPath: report) {
                Button(t("查看报告")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
                }
                .buttonStyle(.link)
                .font(Typography.caption)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 1))
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typography.micro)
                .foregroundColor(theme.textSecondary)
            Text(text)
                .font(Typography.label.weight(.semibold).monospaced())
                .foregroundColor(theme.textPrimary)
        }
    }

    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
}

// MARK: - Mode picker

/// Shown before a session starts. Two independent choices: how deep the cycle
/// goes (the preset) and how hard the pack is drained (the stress mode). Both
/// are deliberate, so neither is inherited silently from the last run.
struct CalibrationModeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    private var theme: Theme { Theme.current }

    @State private var preset = CalibrationEngine.shared.preset
    @State private var stress = CalibrationEngine.shared.stressMode
    /// A deep cycle is the only one that takes the pack close to empty, so it
    /// takes a second confirmation instead of one tap.
    @State private var confirmingDeep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("选择校准方式"))
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Text(t("深度决定测量是否完整，负载决定放电快慢。深度越深，耗时和损耗越大。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(CalibrationPreset.allCases) { item in
                Button {
                    preset = item
                    confirmingDeep = false
                } label: {
                    presetRow(item)
                }
                .buttonStyle(.plain)
            }

            Divider().background(theme.divider)

            HStack(spacing: 7) {
                Text(t("放电负载"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                ForEach(DischargeStressMode.allCases) { mode in
                    ChipButton(title: mode.title, symbol: symbol(mode),
                               selected: stress == mode) { stress = mode }
                }
                Spacer(minLength: 0)
            }

            if preset.requiresExplicitUserAction {
                Text(t("深度校准会把电量放到约 10%，电池将在接近放空的状态下工作。非必要不建议频繁执行。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.chartOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(t("取消")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typography.body)
                    .foregroundColor(theme.textSecondary)
                Button(confirmingDeep ? t("确认开始深度校准") : t("开始校准")) {
                    guard !(preset.requiresExplicitUserAction && !confirmingDeep) else {
                        confirmingDeep = true
                        return
                    }
                    state.startCalibration(preset: preset, mode: stress)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(Typography.headline)
                .foregroundColor(confirmingDeep ? theme.chartOrange : theme.accent)
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(theme.windowBackground)
    }

    private func presetRow(_ item: CalibrationPreset) -> some View {
        let selected = preset == item
        return HStack(spacing: 10) {
            Image(systemName: symbol(item))
                .font(Glyph.row)
                .frame(width: 20)
                .foregroundColor(selected ? theme.accent : theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Typography.headline)
                        .foregroundColor(theme.textPrimary)
                    Text(item.estimatedHours)
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                }
                Text(item.detail)
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                Text(item.risk)
                    .font(Typography.caption)
                    .foregroundColor(item.capsQualityAtLow || item.requiresExplicitUserAction
                                     ? theme.chartOrange : theme.textTertiary)
            }
            Spacer(minLength: 6)
            if selected {
                Image(systemName: "checkmark")
                    .font(Glyph.inline.weight(.bold))
                    .foregroundColor(theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? theme.selectedSidebar : theme.innerControl))
    }

    private func symbol(_ item: CalibrationPreset) -> String {
        switch item {
        case .quickCheck: return "bolt.badge.clock"
        case .standard: return "arrow.triangle.2.circlepath"
        case .deep: return "arrow.down.to.line"
        }
    }

    private func symbol(_ mode: DischargeStressMode) -> String {
        switch mode {
        case .silent: return "speaker.slash"
        case .balanced: return "gauge.medium"
        case .aggressive: return "flame"
        }
    }
}
