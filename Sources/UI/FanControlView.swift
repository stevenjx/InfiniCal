//
//  FanControlView.swift
//  风扇控制：真实转速读写、温度遥测、曲线与预设。
//

import SwiftUI

struct FanControlPage: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var controller = FanController.shared
    @StateObject private var showAllSensors = UIFlag()
    private var theme: Theme { Theme.current }

    var body: some View {
        PageScaffold(title: Panel.fanControl.title,
                     symbol: Panel.fanControl.symbol,
                     help: t("直接读写 SMC 的风扇目标转速与模式键：自动交给系统，自定义与全速由本 App 强制。退出 App 时自动恢复系统控制。"),
                     toolbar: { statusPill }) {
            if controller.hasFans {
                // Side by side: a two-fan machine fits both in one row, and
                // a single fan simply fills the width.
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(controller.fans) { fan in
                        FanCard(fan: fan, controller: controller)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                noFanCard
            }

            // Stacked, not side by side. Measured on this 1080×720 window: the
            // two cards are 164 and 179 pt tall, so a two-column row ends at
            // y 478 and leaves 218 pt of empty page below it — 130 pt more than
            // the layout it replaced. Stacked, the page ends at 684 with 12 pt
            // to spare, and the fan cards grew by 59 pt to get there.
            temperatureCard
            curveCard

            presetRow

            if !state.helperInstalled {
                helperNotice
            }

            if let error = controller.lastError {
                Text(error)
                    .font(Typography.caption)
                    .foregroundColor(theme.danger)
            }
        }
        .onAppear { controller.beginMonitoring() }
        .onDisappear { controller.endMonitoring() }
    }

    private var statusPill: some View {
        let manual = controller.isAnyManual || controller.curveEnabled
        return HStack(spacing: Spacing.xs) {
            Image(systemName: manual ? "hand.raised.fill" : "gearshape.2.fill")
                .font(Glyph.inline.weight(.bold))
            Text(manual ? t("手动控制") : t("系统自动"))
                .font(Typography.label)
        }
        .foregroundColor(manual ? theme.chartOrange : theme.chartGreen)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill((manual ? theme.chartOrange : theme.chartGreen).opacity(theme.isDark ? 0.18 : 0.12)))
    }

    private var noFanCard: some View {
        Card {
            EmptyState(symbol: "wind",
                       title: t("此机型没有风扇"),
                       message: t("SMC 未报告任何风扇（FNum = 0），散热完全被动。温度数据仍然可用。"),
                       layout: .inline)
        }
    }

    private var helperNotice: some View {
        Card(padding: .compact) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "lock.shield")
                    .font(Glyph.row)
                    .foregroundColor(theme.textSecondary)
                Text(t("调整风扇需要特权助手（写入 SMC 必须 root）"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Button { state.installHelper() } label: {
                    Text(t("安装"))
                        .font(Typography.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Temperature

    private var temperatureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: t("温度"), symbol: "thermometer.medium", tint: theme.chartBlue) {
                    Text(t("1 Hz 实时"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                }

                if controller.sensors.isEmpty {
                    Text(t("未读到温度传感器"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(controller.sensors) { sensor in
                            temperatureRow(sensor)
                        }
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllSensors.value.toggle() }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: showAllSensors.value ? "chevron.down" : "chevron.right")
                            .font(Glyph.inline.weight(.semibold))
                        Text(showAllSensors.value ? t("收起全部传感器") : t("显示全部传感器"))
                            .font(Typography.caption)
                    }
                    .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)

                if showAllSensors.value {
                    let all = controller.allHIDSensors()
                    if all.isEmpty {
                        Text(t("HID 未报告可用的温度服务"))
                            .font(Typography.caption)
                            .foregroundColor(theme.textTertiary)
                    } else {
                        VStack(spacing: Spacing.xxs) {
                            ForEach(all) { sensor in
                                HStack(spacing: Spacing.xs) {
                                    Text(sensor.name)
                                        .font(Typography.caption.monospaced())
                                        .foregroundColor(theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: Spacing.xs)
                                    Text(String(format: "%.1f °C", sensor.celsius))
                                        .font(Typography.micro.monospacedDigit())
                                        .foregroundColor(theme.textPrimary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func temperatureRow(_ sensor: ThermalReading) -> some View {
        let fraction = min(1, max(0, (sensor.celsius - 20) / 80))
        let tint: Color = sensor.celsius >= 90 ? theme.danger
            : (sensor.celsius >= 75 ? theme.warning : theme.chartBlue)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(sensor.name)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Text(sensor.source)
                    .font(Typography.micro)
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                Text(String(format: "%.1f", sensor.celsius))
                    .font(Typography.headline.monospacedDigit())
                    .foregroundColor(tint)
                    .numericTextTransition()
                Text("°C")
                    .font(Typography.micro)
                    .foregroundColor(theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.innerControl)
                    Capsule().fill(tint.opacity(0.75))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Curve

    private var curveCard: some View {
        let enabled = controller.curveEnabled
        return Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CardHeader(title: t("温度曲线"), symbol: "chart.line.uptrend.xyaxis",
                           tint: theme.chartPurple,
                           help: t("按选定传感器温度分三段调整转速：低于起始温度保持最低转速，中点给一个中间转速，达到满载温度时全速。每秒更新一次，温度变化小于 1°C 时不重写，转速每秒最多变化 150 RPM。")) {
                    HStack(spacing: Spacing.s) {
                        if !enabled { OffBadge(text: t("已关闭")) }
                        Toggle("", isOn: Binding(get: { controller.curveEnabled },
                                                 set: { controller.setCurveEnabled($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(theme.accent)
                            .scaleEffect(0.78)
                            .frame(width: 40, height: 20)
                            .disabled(!controller.hasFans)
                    }
                }

                // Two rows of three, as before: at full width a stacked form
                // would leave 400 pt of nothing beside each control.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        curveLabel(t("传感器"))
                        Picker("", selection: Binding(get: { controller.curveSensorKey },
                                                      set: { controller.setCurveSensor($0) })) {
                            ForEach(curveSensorOptions, id: \.key) { option in
                                Text(option.name).tag(option.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        curveLabel(t("起始"))
                        ValueStepper(value: Binding(get: { Int(controller.curveStartTemperature) },
                                                    set: { controller.curveStartTemperature = Double($0) }),
                                     range: 30...80, step: 1, suffix: "°C")
                            .frame(width: 96)

                        curveLabel(t("满载"))
                        ValueStepper(value: Binding(get: { Int(controller.curvePeakTemperature) },
                                                    set: { controller.curvePeakTemperature = Double($0) }),
                                     range: 50...105, step: 1, suffix: "°C")
                            .frame(width: 96)

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: Spacing.s) {
                        curveLabel(t("中点"))
                        ValueStepper(value: Binding(get: { Int(controller.curveMidTemperature) },
                                                    set: { controller.curveMidTemperature = Double($0) }),
                                     range: 40...100, step: 1, suffix: "°C")
                            .frame(width: 96)

                        curveLabel(t("转速"))
                        ValueStepper(value: Binding(get: { Int(controller.curveMidPercent) },
                                                    set: { controller.curveMidPercent = Double($0) }),
                                     range: 0...100, step: 5, suffix: "%")
                            .frame(width: 96)

                        Spacer(minLength: 0)
                    }
                }
                .opacity(enabled ? 1 : 0.35)
                .disabled(!enabled)

                // One line that is always present, so toggling the curve does
                // not change the card's height.
                Text(curveFooter)
                    .font(Typography.caption)
                    .foregroundColor(enabled ? theme.chartPurple : theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func curveLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.label)
            .foregroundColor(theme.textSecondary)
            .frame(width: 40, alignment: .leading)
    }

    private var curveFooter: String {
        guard controller.curveEnabled else { return t("三段折线：起始 → 中点 → 满载") }
        guard let current = curveCurrentTemperature else { return t("等待传感器读数") }
        return tf("当前 {p}°C → {p}", String(format: "%.1f", current), curveTargetText)
    }

    private var curveSensorOptions: [ThermalReading] {
        controller.sensors
    }

    private var curveCurrentTemperature: Double? {
        controller.sensors.first { $0.key == controller.curveSensorKey }?.celsius
    }

    private var curveTargetText: String {
        guard let temperature = curveCurrentTemperature,
              let rpm = controller.projectedRPM(temperature: temperature) else { return "--" }
        return "\(rpm) RPM"
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: Spacing.s) {
            Text(t("预设"))
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)

            ChipButton(title: t("自动"), symbol: "gearshape.2", selected: !controller.isAnyManual && !controller.curveEnabled) {
                controller.setAllAuto()
            }
            ChipButton(title: t("全速"), symbol: "wind", selected: controller.fans.allSatisfy { $0.isManual && $0.targetRPM >= $0.maxRPM - 20 } && controller.hasFans) {
                controller.setAllFull()
            }

            ForEach(controller.presets) { preset in
                ChipButton(title: preset.name, symbol: "bookmark", selected: controller.activePresetName == preset.name) {
                    controller.apply(preset)
                }
            }

            Spacer(minLength: Spacing.s)

            SmallActionButton(title: t("保存当前"), symbol: "plus") {
                savePreset()
            }
            .frame(width: 96)
        }
    }

    private func savePreset() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        controller.savePreset(named: tf("预设 {p}", formatter.string(from: Date())))
    }
}

// MARK: - Badges

/// A state label inside a card: neutral grey, because "已关闭" is an absence
/// rather than a warning. The page's own status pill is a different weight —
/// it reports what the app is doing, not what one card is not.
private struct OffBadge: View {
    private var theme: Theme { Theme.current }
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.micro)
            .foregroundColor(theme.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.innerControl))
    }
}

// MARK: - Speed ring

/// The fan's current speed as an arc, with the same fan icon in the middle that
/// the card used to draw at 18 pt. The arc is the at-a-glance reading; the
/// figure beside it is the exact one.
///
/// A stopped fan draws no arc at all rather than a minimum sliver: on this
/// machine both fans idle at 0 RPM, and a 2 % arc would claim motion that is
/// not happening.
private struct SpeedRing: View {
    private var theme: Theme { Theme.current }
    let ratio: Double
    let tint: Color
    var size: CGFloat = 62

    private var lineWidth: CGFloat { 6 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.innerControl, lineWidth: lineWidth)
            if ratio > 0.001 {
                Circle()
                    .trim(from: 0, to: min(1, ratio))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "fanblades.fill")
                .font(Glyph.block)
                .foregroundColor(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Fan card

private struct FanCard: View {
    private var theme: Theme { Theme.current }
    let fan: FanInfo
    @ObservedObject var controller: FanController

    private var mode: FanMode { controller.modes[fan.index] ?? .auto }
    private var tint: Color { fan.isManual ? theme.chartOrange : theme.chartPurple }

    /// Current speed as a share of the fan's top speed.
    ///
    /// Not `(current − min) / (max − min)`: this machine's floor is 2,317 RPM,
    /// so a fan idling at 2,328 RPM would draw a 0.2 % arc — a spinning fan
    /// that looks stopped. Zero on the ring means zero RPM.
    private var ratio: Double {
        guard fan.maxRPM > 0 else { return 0 }
        return min(1, max(0, Double(fan.currentRPM) / Double(fan.maxRPM)))
    }

    /// Built as a `String` on purpose: written inline it would become a
    /// localised key and print SMC values with grouping separators.
    private var smcLine: String {
        "SMC F\(fan.index)Tg = \(fan.targetRPM) · F\(fan.index)Md = \(fan.isManual ? 1 : 0)"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "fanblades.fill")
                        .font(Glyph.row)
                        .foregroundColor(tint)
                    Text(fan.name)
                        .font(Typography.headline)
                        .foregroundColor(theme.textPrimary)
                    Spacer(minLength: Spacing.s)
                }

                HStack(alignment: .center, spacing: Spacing.l) {
                    // Ring on the left, its scale underneath — the two numbers
                    // used to sit beside the RPM figure, which is what made the
                    // top-right corner crowded.
                    VStack(spacing: Spacing.xs) {
                        SpeedRing(ratio: ratio, tint: tint)
                        Text("0 – \(fan.maxRPM) RPM")
                            .font(Typography.micro.monospacedDigit())
                            .foregroundColor(theme.textTertiary)
                            .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            Text("\(fan.currentRPM)")
                                .font(Typography.display)
                                .foregroundColor(theme.textPrimary)
                                .numericTextTransition()
                            Text("RPM")
                                .font(Typography.micro)
                                .foregroundColor(theme.textSecondary)
                        }
                        Text(modeCaption)
                            .font(Typography.caption)
                            .foregroundColor(theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                if !controller.curveEnabled {
                    controlArea
                }

                if !fan.canControl {
                    Text(t("此机型未暴露可写的风扇模式键，只能读取转速"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(smcLine)
                    .font(Typography.micro.monospacedDigit())
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var modeCaption: String {
        if controller.curveEnabled { return t("由温度曲线控制") }
        switch mode {
        case .auto: return t("由系统按温度自动调节")
        case .full: return t("保持最大转速")
        case .fixed: return t("按设定转速运行")
        }
    }

    private var controlArea: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Picker("", selection: Binding(get: { mode }, set: { controller.setMode($0, for: fan.index) })) {
                Text(t("自动")).tag(FanMode.auto)
                Text(t("自定义")).tag(FanMode.fixed)
                Text(t("全速")).tag(FanMode.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            if mode == .fixed {
                HStack(spacing: Spacing.s) {
                    Slider(value: Binding(get: { Double(controller.fixedRPM[fan.index] ?? fan.currentRPM) },
                                          set: { controller.setFixedRPM(Int($0.rounded()), for: fan.index) }),
                           in: Double(fan.minRPM)...Double(max(fan.minRPM + 1, fan.maxRPM)),
                           step: 50)
                    .tint(theme.accent)
                    Text("\(controller.fixedRPM[fan.index] ?? fan.currentRPM)")
                        .font(Typography.micro.monospacedDigit())
                        .foregroundColor(theme.textPrimary)
                        .frame(width: 46, alignment: .trailing)
                    Text("RPM")
                        .font(Typography.micro)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        // Read-only models keep the control on screen — hiding it would suggest
        // the mode does not exist — but at 35 % with clicks refused.
        .opacity(fan.canControl ? 1 : 0.35)
        .disabled(!fan.canControl)
    }
}
