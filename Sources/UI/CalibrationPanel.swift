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
                .padding(22)
        }
    }
}

struct CalibrationPanel: View {
    @ObservedObject private var engine = CalibrationEngine.shared
    @ObservedObject private var fans = FanController.shared
    @StateObject private var showHistory = UIFlag()
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusCard
            pipelineCard
            HStack(alignment: .top, spacing: 10) {
                enduranceCard
                healthCard
            }
            HStack(spacing: 10) {
                hostCard(title: t("CPU 功耗"),
                         value: String(format: "%.1f", engine.cpuPowerWatts),
                         unit: "W",
                         symbol: "cpu",
                         tint: theme.chartOrange,
                         progress: min(1, engine.cpuPowerWatts / 50))
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
            .frame(height: 158)
            controlBar
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
                .font(.system(size: 13))
                .foregroundColor(theme.textPrimary)
            HelpDot(text: t("完整走一遍 满充 → 受控放电 → 复充 → 静置 → 回落 的循环，用库仑积分算出电池真实的满充容量与健康度。全过程本地完成，不依赖任何第三方 App。"))
            if let last = engine.lastCalibrationDate {
                Text(tf("上次校准 {p}", Self.lastRun.string(from: last)))
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
            }
            Spacer()
            if engine.phase != .idle { statusPill }
            Button {
                if engine.isRunning { AppState.shared.stopCalibration() } else { AppState.shared.startCalibration() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                    Text(engine.isRunning ? t("停止校准") : t("开始校准"))
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(engine.isRunning ? Color.red.opacity(0.18) : theme.accent))
                .foregroundColor(engine.isRunning ? Color.red : .white)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 34)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Image(systemName: engine.phase.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(engine.phase.title)
                .font(.system(size: 11, weight: .medium))
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

    // MARK: - Live status

    private var statusCard: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    CalibrationRing(percentage: engine.percentage,
                                    isCharging: engine.isCharging,
                                    isDischarging: engine.signedAmperage < -0.05,
                                    accent: theme.chartBlue)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(engine.percentage)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(theme.textPrimary)
                                .monospacedDigit()
                            Text("%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.textSecondary)
                        }
                        Text(powerStateText)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(engine.isExternalConnected ? theme.chartGreen : theme.textTertiary)
                                .frame(width: 5, height: 5)
                            Text(tf("设计 {p} mAh · 固件满充 {p} mAh", "\(Int(engine.designCapacityMAh))", "\(Int(engine.rawMaxCapacityMAh))"))
                                .font(.system(size: 9.5))
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
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.textTertiary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 9))
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
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.textSecondary)
                    Text(t("校准流程"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    Text(pipelineProgressText)
                        .font(.system(size: 10))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
            }
            Text(stepTitle(phase))
                .font(.system(size: 9.5, weight: isActive ? .bold : .regular))
                .foregroundColor(isActive ? theme.textPrimary : theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(height: 24, alignment: .top)
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
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("clock", t("续航评估"), tint: theme.chartOrange) {
                    if engine.aiRemainingMinutes > 0 {
                        Text(t("AI 预测"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.chartPurple)
                    }
                }

                let minutes = engine.aiRemainingMinutes > 0 ? engine.aiRemainingMinutes : engine.estimatedRemainingMinutes
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Self.duration(minutes))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(minutes > 0 ? theme.chartOrange : theme.textSecondary)
                        .monospacedDigit()
                    Text(t("预计可用"))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textSecondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    metric(t("全周期耗时"), Self.duration(engine.totalDischargeRuntimeMinutes), "", "hourglass", theme.textPrimary)
                    metric(t("平均放电功耗"), String(format: "%.1f", engine.dischargeAveragePower), "W", "bolt.slash", theme.textPrimary)
                }
            }
        }
    }

    private var healthCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("heart", t("健康度与容量"), tint: theme.chartBlue) {
                    if engine.aiConfidence > 0 {
                        Text(tf("置信度 {p}%", "\(Int(engine.aiConfidence))"))
                            .font(.system(size: 9))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                let health = engine.measuredHealth > 0 ? engine.measuredHealth : engine.aiTrueHealthPercent
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(health > 0 ? String(format: "%.1f", health) : "--")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(health >= 80 ? theme.chartGreen : (health > 0 ? theme.chartOrange : theme.textSecondary))
                        .monospacedDigit()
                    if health > 0 {
                        Text("%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.textSecondary)
                    }
                    Text(t("电池健康度"))
                        .font(.system(size: 9))
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
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func cardTitle<T: View>(_ symbol: String, _ title: String, tint: Color,
                                    @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.textPrimary)
            Spacer(minLength: 6)
            trailing()
        }
    }

    // MARK: - Host telemetry

    private func hostCard(title: String, value: String, unit: String,
                          symbol: String, tint: Color, progress: Double) -> some View {
        Card(padding: 10) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(tint.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.04, min(1, progress))))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(theme.textPrimary)
                            .monospacedDigit()
                        Text(unit)
                            .font(.system(size: 9))
                            .foregroundColor(theme.textSecondary)
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

        return Card(padding: 10) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(theme.chartPurple.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(ceiling > 0 ? min(1, Double(current) / Double(ceiling)) : 0))
                        .stroke(theme.chartPurple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(hasFan ? theme.chartPurple : theme.textTertiary)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(t("风扇转速"))
                        .font(.system(size: 10))
                        .foregroundColor(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(hasFan ? "\(current)" : "--")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(hasFan ? theme.textPrimary : theme.textSecondary)
                            .monospacedDigit()
                        Text("RPM")
                            .font(.system(size: 9))
                            .foregroundColor(theme.textSecondary)
                    }
                    Text(hasFan
                         ? (current > 0 ? tf("最高 · {p} 个风扇", "\(readings.count)") : t("已停转（正常待机）"))
                         : t("此机型无风扇"))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Scopes

    private func scopeCard(title: String, badge: String, badgeUnit: String, tint: Color,
                           domain: ClosedRange<Double>, steps: [Double], unit: String,
                           points: [CalibrationSample],
                           keyPath: KeyPath<CalibrationSample, Double>) -> some View {
        Card(padding: 10) {
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
                Text(t("放电负载"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize()
                Picker("", selection: Binding(get: { engine.stressMode },
                                              set: { engine.stressMode = $0 })) {
                    ForEach(DischargeStressMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 176)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.innerControl))

            HStack(spacing: 6) {
                Text(t("放电至"))
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
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

            if engine.isThermalCutoffActive {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.sun.fill").font(.system(size: 9, weight: .bold))
                    Text(t("温度保护中")).font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let selected = probe.value {
                    HStack(spacing: 5) {
                        Text(Self.time.string(from: selected.timestamp))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                        Text("\(String(format: "%.1f", selected[keyPath: keyPath])) \(unit)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(tint)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(badge)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(tint)
                        Text(badgeUnit)
                            .font(.system(size: 9))
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
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 8, design: .monospaced))
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
                .font(.system(size: 8, design: .monospaced))
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

private struct CalibrationHistorySheet: View {
    @ObservedObject var engine: CalibrationEngine
    @Binding var isPresented: Bool
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(theme.accent)
                Text(t("历史校准记录"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                if !engine.records.isEmpty {
                    Button(t("清空")) { engine.clearHistory() }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                }
                Button(t("完成")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider().background(theme.divider)

            if engine.records.count >= 2 {
                trendBlock
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            if engine.records.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "archivebox")
                        .font(.system(size: 32))
                        .foregroundColor(theme.textTertiary)
                    Text(t("还没有校准记录"))
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                    Text(t("完成一次校准后，结果会自动保存在这里"))
                        .font(.system(size: 10.5))
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
        .frame(width: 620, height: 580)
        .background(theme.windowBackground)
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
        Card(padding: 12) {
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Text(String(format: "SOH %.1f%%", record.batteryHealthPercentage))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill((record.batteryHealthPercentage >= 80 ? Color.green : Color.orange).opacity(0.14)))
                    .foregroundColor(record.batteryHealthPercentage >= 80 ? .green : .orange)
                Button {
                    engine.deleteRecord(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(theme.textTertiary)
                }
                .buttonStyle(.plain)
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

            if let report = record.reportFilePath, FileManager.default.fileExists(atPath: report) {
                Button(t("查看报告")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
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
                .font(.system(size: 9))
                .foregroundColor(theme.textSecondary)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
