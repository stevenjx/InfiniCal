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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header

                if controller.hasFans {
                    ForEach(controller.fans) { fan in
                        FanCard(fan: fan, controller: controller)
                    }
                } else {
                    noFanCard
                }

                temperatureCard
                curveCard
                presetRow

                if !state.helperInstalled {
                    helperNotice
                }

                if let error = controller.lastError {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundColor(.red.opacity(0.85))
                        .padding(.top, 2)
                }
            }
            .padding(22)
        }
        .onAppear { controller.beginMonitoring() }
        .onDisappear { controller.endMonitoring() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "fanblades")
            Text(t("风扇控制"))
                .font(.system(size: 13))
                .foregroundColor(theme.textPrimary)
            HelpDot(text: t("直接读写 SMC 的风扇目标转速与模式键：自动交给系统，自定义与全速由本 App 强制。退出 App 时自动恢复系统控制。"))
            Spacer()
            statusPill
        }
        .frame(height: 34)
    }

    private var statusPill: some View {
        let manual = controller.isAnyManual || controller.curveEnabled
        return HStack(spacing: 5) {
            Image(systemName: manual ? "hand.raised.fill" : "gearshape.2.fill")
                .font(.system(size: 9, weight: .bold))
            Text(manual ? t("手动控制") : t("系统自动"))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(manual ? theme.chartOrange : theme.chartGreen)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill((manual ? theme.chartOrange : theme.chartGreen).opacity(theme.isDark ? 0.18 : 0.12)))
    }

    private var noFanCard: some View {
        Card(padding: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .font(.system(size: 18))
                    .foregroundColor(theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("此机型没有风扇"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                    Text(t("SMC 未报告任何风扇（FNum = 0），散热完全被动。温度数据仍然可用。"))
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var helperNotice: some View {
        Card(padding: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Text(t("调整风扇需要特权助手（写入 SMC 必须 root）"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Button { state.installHelper() } label: {
                    Text(t("安装"))
                        .font(.system(size: 11, weight: .medium))
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
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.chartBlue)
                    Text(t("温度"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    Spacer()
                    Text(t("1 Hz 实时"))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                }

                if controller.sensors.isEmpty {
                    Text(t("未读到温度传感器"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                } else {
                    ForEach(controller.sensors) { sensor in
                        temperatureRow(sensor)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllSensors.value.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showAllSensors.value ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(showAllSensors.value ? t("收起全部传感器") : t("显示全部传感器"))
                            .font(.system(size: 10.5))
                    }
                    .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)

                if showAllSensors.value {
                    let all = controller.allHIDSensors()
                    if all.isEmpty {
                        Text(t("HID 未报告可用的温度服务"))
                            .font(.system(size: 10))
                            .foregroundColor(theme.textTertiary)
                    } else {
                        VStack(spacing: 3) {
                            ForEach(all) { sensor in
                                HStack(spacing: 6) {
                                    Text(sensor.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(String(format: "%.1f °C", sensor.celsius))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(theme.textPrimary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func temperatureRow(_ sensor: ThermalReading) -> some View {
        let fraction = min(1, max(0, (sensor.celsius - 20) / 80))
        let tint: Color = sensor.celsius >= 90 ? .red : (sensor.celsius >= 75 ? theme.chartOrange : theme.chartBlue)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sensor.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                Text(sensor.source)
                    .font(.system(size: 9))
                    .foregroundColor(theme.textTertiary)
                Spacer()
                Text(String(format: "%.1f", sensor.celsius))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                Text("°C")
                    .font(.system(size: 9))
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
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.chartPurple)
                    Text(t("温度曲线"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                    HelpDot(text: t("按选定传感器温度分三段调整转速：低于起始温度保持最低转速，中点给一个中间转速，达到满载温度时全速。每秒更新一次，温度变化小于 1°C 时不重写，转速每秒最多变化 150 RPM。"))
                    Spacer()
                    Toggle("", isOn: Binding(get: { controller.curveEnabled }, set: { controller.setCurveEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accent)
                    .scaleEffect(0.78)
                    .frame(width: 40, height: 20)
                    .disabled(!controller.hasFans)
                }

                HStack(spacing: 10) {
                    Text(t("传感器"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    Picker("", selection: Binding(get: { controller.curveSensorKey },
                                                  set: { controller.setCurveSensor($0) })) {
                        ForEach(curveSensorOptions, id: \.key) { option in
                            Text(option.name).tag(option.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(!controller.curveEnabled)

                    Text(t("起始"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    ValueStepper(value: Binding(get: { Int(controller.curveStartTemperature) },
                                                set: { controller.curveStartTemperature = Double($0) }),
                                 range: 30...80, step: 1, suffix: "°C")
                        .frame(width: 96)
                        .disabled(!controller.curveEnabled)

                    Text(t("满载"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    ValueStepper(value: Binding(get: { Int(controller.curvePeakTemperature) },
                                                set: { controller.curvePeakTemperature = Double($0) }),
                                 range: 50...105, step: 1, suffix: "°C")
                        .frame(width: 96)
                        .disabled(!controller.curveEnabled)

                    Spacer(minLength: 0)
                }
                .opacity(controller.hasFans ? 1 : 0.5)

                HStack(spacing: 10) {
                    Text(t("中点"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    ValueStepper(value: Binding(get: { Int(controller.curveMidTemperature) },
                                                set: { controller.curveMidTemperature = Double($0) }),
                                 range: 40...100, step: 1, suffix: "°C")
                        .frame(width: 96)
                        .disabled(!controller.curveEnabled)

                    Text(t("转速"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                    ValueStepper(value: Binding(get: { Int(controller.curveMidPercent) },
                                                set: { controller.curveMidPercent = Double($0) }),
                                 range: 0...100, step: 5, suffix: "%")
                        .frame(width: 96)
                        .disabled(!controller.curveEnabled)

                    Spacer(minLength: 0)

                    Text(t("三段折线：起始 → 中点 → 满载"))
                        .font(.system(size: 9))
                        .foregroundColor(theme.textTertiary)
                }
                .opacity(controller.hasFans ? 1 : 0.5)

                if controller.curveEnabled, let current = curveCurrentTemperature {
                    Text(tf("当前 {p}°C → {p}", String(format: "%.1f", current), curveTargetText))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textTertiary)
                }
            }
        }
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
        HStack(spacing: 8) {
            Text(t("预设"))
                .font(.system(size: 11))
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

            Spacer(minLength: 8)

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

// MARK: - Fan card

private struct FanCard: View {
    private var theme: Theme { Theme.current }
    let fan: FanInfo
    @ObservedObject var controller: FanController

    private var mode: FanMode { controller.modes[fan.index] ?? .auto }
    private var tint: Color { fan.isManual ? theme.chartOrange : theme.chartPurple }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 16))
                        .foregroundColor(tint)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(fan.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.textPrimary)
                        Text("SMC F\(fan.index)Tg = \(fan.targetRPM) · F\(fan.index)Md = \(fan.isManual ? 1 : 0)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(theme.textTertiary)
                    }

                    Spacer(minLength: 8)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(fan.currentRPM)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(theme.textPrimary)
                            .monospacedDigit()
                        Text("RPM")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.textSecondary)
                    }
                }

                rangeBar

                if controller.curveEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 9, weight: .semibold))
                        Text(t("由温度曲线控制"))
                            .font(.system(size: 10.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(theme.chartPurple)
                } else {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { mode }, set: { controller.setMode($0, for: fan.index) })) {
                            Text(t("自动")).tag(FanMode.auto)
                            Text(t("自定义")).tag(FanMode.fixed)
                            Text(t("全速")).tag(FanMode.full)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 196)
                        .disabled(!fan.canControl)

                        if mode == .fixed {
                            Slider(value: Binding(get: { Double(controller.fixedRPM[fan.index] ?? fan.currentRPM) },
                                                  set: { controller.setFixedRPM(Int($0.rounded()), for: fan.index) }),
                                   in: Double(fan.minRPM)...Double(max(fan.minRPM + 1, fan.maxRPM)),
                                   step: 50)
                            .tint(theme.accent)
                            Text("\(controller.fixedRPM[fan.index] ?? fan.currentRPM)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.textPrimary)
                                .frame(width: 46, alignment: .trailing)
                            Text("RPM")
                                .font(.system(size: 9))
                                .foregroundColor(theme.textSecondary)
                        } else {
                            Text(mode == .auto ? t("由系统按温度自动调节") : t("保持最大转速"))
                                .font(.system(size: 10))
                                .foregroundColor(theme.textTertiary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if !fan.canControl {
                    Text(t("此机型未暴露可写的风扇模式键，只能读取转速"))
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.textTertiary)
                }
            }
        }
    }

    /// Current speed as a position inside the fan's own min…max range.
    private var rangeBar: some View {
        HStack(spacing: 7) {
            Text("\(fan.minRPM)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.textTertiary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { geo in
                let span = max(1, fan.maxRPM - fan.minRPM)
                let ratio = min(1, max(0, Double(fan.currentRPM - fan.minRPM) / Double(span)))
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.innerControl)
                        .frame(height: 5)
                        .overlay(Capsule().strokeBorder(theme.cardStroke, lineWidth: 0.5))
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: max(5, width * CGFloat(ratio)), height: 5)
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(theme.card, lineWidth: 1.5))
                        .offset(x: min(max(0, width * CGFloat(ratio) - 4), max(0, width - 8)))
                }
                .frame(height: 8)
            }
            .frame(height: 8)

            Text("\(fan.maxRPM)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.textTertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
