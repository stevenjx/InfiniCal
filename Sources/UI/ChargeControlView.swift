//
//  ChargeControlView.swift
//

import SwiftUI

struct ChargeControlView: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        PageScaffold(title: Panel.chargeControl.title,
                     symbol: Panel.chargeControl.symbol,
                     help: t("设置电池允许充到的最高电量。达到该数值后 InfiniCal 会暂停充电，让 MacBook 直接使用电源适配器供电。"),
                     toolbar: { headerToolbar }) {
            notices

            controlCard

            if let adapter = state.adapterDiagnosis {
                SectionLabel(text: t("电源适配器"))
                adapterCard(adapter)
            }

            SectionLabel(text: t("按时间充满"))
            smartChargeCard

            if !state.helperInstalled { helperNotice }
        }
    }

    // MARK: - Header

    /// Current state, then the limit. The state was nowhere on this page: the
    /// only thing that described it was `statusNote`, an 11 pt tertiary line at
    /// the very bottom, and it is empty most of the time.
    private var headerToolbar: some View {
        HStack(spacing: Spacing.m) {
            statePill
            HStack(spacing: Spacing.s) {
                Text(t("充电限制"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                ValueStepper(value: Binding(get: { state.chargeVal },
                                            set: { state.userSetLimit($0) }),
                             range: state.allowBelow80 && ChargeController.shared.canSetBelow80 ? 1...100 : 80...100,
                             step: 5)
                    .frame(width: 108)
            }
        }
    }

    /// Dot for the colour, `textPrimary` for the word. The fan page tints the
    /// label too, and `chartOrange` as text is 2.2:1 on a white card.
    private var statePill: some View {
        HStack(spacing: Spacing.xs + Spacing.xxs) {
            Circle()
                .fill(stateTint)
                .frame(width: 6, height: 6)
            Text(state.chargeState.title)
                .font(Typography.label)
                .foregroundColor(theme.textPrimary)
        }
        .padding(.horizontal, Spacing.s + Spacing.xxs)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(stateTint.opacity(theme.isDark ? 0.18 : 0.12)))
    }

    /// `paused` is grey, not `warning`: reaching the limit pauses charging, and
    /// that is the app working, not something to alarm the reader about. The
    /// one genuinely abnormal state on this page is the arbitration conflict
    /// below, and that one is orange.
    private var stateTint: Color {
        switch state.chargeState {
        case .charging, .full: return theme.success
        case .paused: return theme.textSecondary
        case .discharging, .calibrating: return theme.accent
        case .noBattery: return theme.danger
        case .noAdapter: return theme.textTertiary
        }
    }

    // MARK: - Notices

    /// Three things can be true at the top of this page, and they used to be
    /// scattered: the conflict line at the bottom in 11 pt tertiary, the top-up
    /// banner as a hand-rolled strip, and `statusNote` at the bottom.
    @ViewBuilder
    private var notices: some View {
        if let arbitration = state.chargeArbitration, arbitration.isConflict {
            alertStrip(symbol: "arrow.triangle.branch",
                       text: tf("当前生效：{p}；已覆盖：{p}",
                                arbitration.winner.strategy.title,
                                arbitration.suppressedTitles))
        }
        // `topUp` writes the same sentence into `statusNote`, so showing both
        // would print it twice, 800 pt apart.
        if let restore = state.topUpRestoreLimit {
            notice(symbol: "bolt.fill",
                   text: tf("一次性充满至 100%，完成后恢复 {p}%", "\(restore)")) {
                Button(t("取消")) { state.cancelTopUp() }
                    .buttonStyle(.plain)
                    .font(Typography.label)
                    .foregroundColor(theme.accent)
            }
        } else if !state.statusNote.isEmpty {
            notice(symbol: "info.circle", text: state.statusNote)
        }
    }

    private func notice<Action: View>(symbol: String, text: String,
                                      @ViewBuilder action: () -> Action) -> some View {
        Card(padding: .compact) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(Glyph.row)
                    .foregroundColor(theme.textSecondary)
                Text(text)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                action()
            }
        }
    }

    private func notice(symbol: String, text: String) -> some View {
        notice(symbol: symbol, text: text) { EmptyView() }
    }

    /// The one state on this page that is genuinely abnormal, so it gets a
    /// filled background instead of the plain card the other two notices use:
    /// the same card every other row sits in does not read as "something is
    /// wrong" from a metre away, however orange the text is.
    ///
    /// 12 % is as far as the tint can go — `warning` text on it measures 4.57:1
    /// in light and 4.64:1 in dark, where 16 % would be 4.32 / 4.31.
    private func alertStrip(symbol: String, text: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(Glyph.row)
                .foregroundColor(theme.warning)
            Text(text)
                .font(Typography.body.weight(.medium))
                .foregroundColor(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
        }
        .padding(.horizontal, CardPadding.regular)
        .padding(.vertical, Spacing.s)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(theme.warning.opacity(0.12)))
    }

    // MARK: - Controls

    /// The four toggles were four bare rows on the window background, each one
    /// separated from the next by a card or a divider. Their sub-settings
    /// (航海差异, 温度上限) were separate full-width cards with the content
    /// centred between two spacers, which read as a dialog rather than as a row.
    private var controlCard: some View {
        Card {
            VStack(spacing: Spacing.xs) {
                ToggleRow(symbol: "exclamationmark.triangle",
                          title: t("允许充电上限低于 80%"),
                          help: t("关闭后，充电限制最低只能设置为 80%。"),
                          isOn: Binding(get: { state.allowBelow80 },
                                        set: { state.allowBelow80 = $0 }))
                Divider().background(theme.divider)
                ToggleRow(symbol: "bolt.slash",
                          title: t("自动放电"),
                          help: t("当电池电量高于充电限制时，自动放电至限制值。"),
                          isOn: $state.automaticDischarge)
                Divider().background(theme.divider)
                ToggleRow(symbol: "sailboat",
                          title: t("航海模式"),
                          help: t("电池电量低于「充电限制 − 差异」时自动恢复充电，避免频繁插拔。"),
                          isOn: $state.sailingMode)
                subRow("arrow.left.and.right", t("差异"), enabled: state.sailingMode,
                       detail: tf("→ 将航海至 {p}%", "\(max(1, state.chargeVal - state.sailingLevel))")) {
                    ValueStepper(value: $state.sailingLevel,
                                 range: 1...max(1, min(30, state.chargeVal - 1)), step: 1)
                        .frame(width: 100)
                }
                Divider().background(theme.divider)
                ToggleRow(symbol: "flame",
                          title: t("过热保护"),
                          help: t("电池温度超过上限时暂停充电，冷却后自动恢复。"),
                          isOn: $state.heatProtectMode)
                subRow("thermometer.medium", t("温度上限"), enabled: state.heatProtectMode,
                       detail: tf("当前 {p}", String(format: "%.1f°C", state.snapshot.temperature))) {
                    ValueStepper(value: $state.maxTemperature, range: 25...60, step: 1, suffix: "°C")
                        .frame(width: 108)
                }
            }
        }
    }

    /// Belongs to the toggle above it: same icon column and same 30 pt height,
    /// but `body` + secondary so it reads as subordinate. Only the control greys
    /// out when its toggle is off — dimming the whole row to 35 %, as the fan
    /// curve does, put this 11 pt caption at about 1.3:1.
    private func subRow<Control: View>(_ symbol: String, _ title: String,
                                       enabled: Bool, detail: String? = nil,
                                       @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Spacing.s) {
            IconBadge(symbol: symbol, color: theme.textSecondary)
            Text(title)
                .font(Typography.body)
                .foregroundColor(theme.textSecondary)
            Spacer(minLength: Spacing.s)
            if let detail {
                Text(detail)
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
            control()
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
        }
        .frame(height: 30)
    }

    // MARK: - Adapter

    /// `success` / `warning` / `danger` rather than `chartGreen` / `chartOrange`:
    /// the chart tokens are one fixed value for both appearances, so on a white
    /// card they measured 3.31:1, 2.16:1 and 3.27:1 — below AA for 15 pt text.
    private func adapterCard(_ adapter: AppState.AdapterDiagnosis) -> some View {
        let status = adapterStatus(adapter)
        return Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Text(tf("输入 {p}", watts(adapter.inputWatts)))
                        .font(Typography.headline.monospacedDigit())
                        .foregroundColor(theme.textPrimary)
                    if adapter.ratedWatts > 0 {
                        Text(tf("· 额定 {p} W", "\(Int(adapter.ratedWatts))"))
                            .font(Typography.caption)
                            .foregroundColor(theme.textTertiary)
                    }
                    Spacer()
                    Text(status.0)
                        .font(Typography.micro)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(status.1.opacity(0.15)))
                        .foregroundColor(status.1)
                }

                HStack(spacing: 0) {
                    adapterMetric(t("系统"), watts(adapter.systemWatts), theme.textPrimary)
                    adapterMetric(t("电池"), batteryText(adapter.batteryWatts),
                                  adapter.batteryWatts < 0 ? theme.danger : theme.success)
                    if adapter.ratedWatts > 0 {
                        adapterMetric(t("余量"), signedWatts(adapter.headroomWatts),
                                      adapter.headroomWatts < 0
                                        ? theme.danger
                                        : (adapter.level == .tight ? theme.warning : theme.textSecondary))
                    }
                }

                if adapter.lossWatts > 0.05 {
                    Text(String(format: t("适配器转换损耗 %.1f W（%.0f%%）"), adapter.lossWatts, adapter.lossPercent))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                }

                if adapter.level == .insufficient {
                    Text(t("当前适配器功率低于系统负载，电池正在放电。换用更大功率的适配器或降低负载。"))
                        .font(Typography.caption)
                        .foregroundColor(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adapterMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(Typography.micro)
                .foregroundColor(theme.textSecondary)
            Text(value)
                .font(Typography.headline.monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adapterStatus(_ adapter: AppState.AdapterDiagnosis) -> (String, Color) {
        switch adapter.level {
        case .good: return (t("余量充足"), theme.success)
        case .tight: return (t("接近满载"), theme.warning)
        case .insufficient: return (t("功率不足"), theme.danger)
        }
    }

    private func batteryText(_ value: Double) -> String {
        value >= 0 ? String(format: t("充 %.1f W"), value) : String(format: t("放 %.1f W"), -value)
    }

    private func watts(_ value: Double) -> String { String(format: "%.1f W", value) }

    private func signedWatts(_ value: Double) -> String {
        value < 0 ? String(format: "-%.1f W", -value) : String(format: "%.1f W", value)
    }

    // MARK: - Smart charge

    private var smartChargeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ToggleRow(symbol: "clock.badge.checkmark",
                          title: t("在指定时间充满"),
                          help: t("其余时间维持上面的充电上限，只在目标时间前把电充满，减少满电静置。开始时间按当前电量与实测充电功率反推。"),
                          isOn: $state.smartChargeEnabled)

                if state.smartChargeEnabled {
                    HStack(spacing: Spacing.s) {
                        Text(t("目标时间"))
                            .font(Typography.body)
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Picker("", selection: $state.smartChargeHour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        Picker("", selection: $state.smartChargeMinute) {
                            ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }

                    // The one line that says when charging will actually start
                    // was 11 pt tertiary, i.e. the dimmest text on the page.
                    Text(state.smartChargeStatusText)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if state.chargeRateWatts > 0.5 {
                        Text(String(format: t("按实测充电功率 %.0f W 估算"), state.chargeRateWatts))
                            .font(Typography.micro)
                            .foregroundColor(theme.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - Helper

    /// Was a bare row on the window background with a hand-rolled capsule.
    private var helperNotice: some View {
        Card(padding: .compact) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "lock.shield")
                    .font(Glyph.row)
                    .foregroundColor(theme.textSecondary)
                Text(tf("写入 SMC 需要特权助手（当前策略：{p}）", state.capabilities.strategy.title))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.s)
                Button {
                    state.installHelper()
                } label: {
                    Text(t("安装"))
                        .font(Typography.label)
                        .padding(.horizontal, Spacing.m)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                        .fill(theme.accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
