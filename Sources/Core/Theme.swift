//
//  Theme.swift
//  Colours and small building blocks shared by every panel.
//

import SwiftUI

struct Theme {
    /// Updated by AppState whenever the appearance setting or the system
    /// appearance changes. Views read it while building their body.
    static var current = Theme(isDark: true)

    let isDark: Bool

    var windowBackground: Color { isDark ? Color(red: 0.11, green: 0.11, blue: 0.115) : Color(red: 0.96, green: 0.96, blue: 0.965) }
    var sidebarBackground: Color { isDark ? Color(red: 0.115, green: 0.115, blue: 0.12) : Color(red: 0.945, green: 0.945, blue: 0.952) }
    var card: Color { isDark ? Color(red: 0.165, green: 0.165, blue: 0.172) : Color.white }
    var cardElevated: Color { isDark ? Color(red: 0.20, green: 0.20, blue: 0.208) : Color.white }
    var innerControl: Color { isDark ? Color(red: 0.235, green: 0.235, blue: 0.245) : Color(red: 0.906, green: 0.906, blue: 0.918) }
    var cardStroke: Color { isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.095) }
    var divider: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.105) }
    /// Outlines a control, not a container: heavier than `cardStroke` so a
    /// button reads as something you can press rather than as a faint edge.
    var border: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.18) }
    var textPrimary: Color { isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.86) }
    /// 62 % / 64 %: explanation copy. Both stay above 6:1 on `card`.
    var textSecondary: Color { isDark ? Color.white.opacity(0.62) : Color.black.opacity(0.64) }
    /// 50 % / 55 %: the lightest text the app allows. Chosen against measured
    /// contrast, not by eye — 34 % / 42 % sat at 3.0:1 while carrying 10–11 pt
    /// labels, and the plan's 48 % / 56 % landed at 4.51 / 4.47, i.e. one point
    /// on each side of the 4.5 line. `Tools/contrast_check.py` enforces this.
    var textTertiary: Color { isDark ? Color.white.opacity(0.50) : Color.black.opacity(0.55) }
    var accent: Color { Color(red: 0.04, green: 0.52, blue: 1.0) }
    var selectedSidebar: Color { isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    /// Keyboard focus ring. Declared here so focus styling has one source; the
    /// focus states themselves arrive with U2-03.
    var focusRing: Color { isDark ? Color(red: 0.29, green: 0.62, blue: 1.0) : Color(red: 0.04, green: 0.42, blue: 0.86) }

    // MARK: - Semantic colours
    //
    // One token per meaning, so a view never writes `Color(red: 1, green: 0.27,
    // blue: 0.23)` to mean "wrong". Values are chosen for ≥ 4.5:1 on `card`;
    // the light variants are the darker halves of the same hue.

    /// #3FB950 / #1A7F37
    var success: Color { isDark ? Color(red: 0.247, green: 0.725, blue: 0.314) : Color(red: 0.102, green: 0.498, blue: 0.216) }
    /// #D29922 / #8A5B00
    var warning: Color { isDark ? Color(red: 0.824, green: 0.600, blue: 0.133) : Color(red: 0.541, green: 0.357, blue: 0.000) }
    /// #FF6B62 / #CF222E — the plan's #F85149 measured 4.28:1 on `card`, so the
    /// dark half is one step brighter.
    var danger: Color { isDark ? Color(red: 1.000, green: 0.420, blue: 0.384) : Color(red: 0.812, green: 0.133, blue: 0.180) }
    /// Neutral notice; the accent is already the "look here" colour.
    var info: Color { accent }

    // MARK: - Series colours
    //
    // The flow diagram and the dashboard chips share one palette. It is brighter
    // than `chart*` on purpose — those sit under a line, these are the line — and
    // the light variants are darker so the same colour works as 10 pt chip text
    // on a white card.

    var flowAdapter: Color { isDark ? Color(red: 0.95, green: 0.72, blue: 0.30) : Color(red: 0.604, green: 0.404, blue: 0.000) }
    var flowSystem: Color { isDark ? Color(red: 0.36, green: 0.58, blue: 0.98) : Color(red: 0.122, green: 0.373, blue: 0.816) }
    var flowBattery: Color { isDark ? Color(red: 0.30, green: 0.78, blue: 0.45) : Color(red: 0.102, green: 0.498, blue: 0.216) }
    var flowSoC: Color { isDark ? Color(red: 0.60, green: 0.53, blue: 1.00) : Color(red: 0.420, green: 0.306, blue: 0.839) }
    var flowUSB: Color { isDark ? Color(red: 0.60, green: 0.60, blue: 0.65) : Color(red: 0.353, green: 0.353, blue: 0.388) }
    var flowOther: Color { isDark ? Color(red: 0.30, green: 0.68, blue: 0.60) : Color(red: 0.102, green: 0.420, blue: 0.369) }

    var chartGreen: Color { Color(red: 0.29, green: 0.62, blue: 0.36) }
    var chartBlue: Color { Color(red: 0.25, green: 0.55, blue: 1.0) }
    var chartPurple: Color { Color(red: 0.60, green: 0.42, blue: 0.95) }
    var chartOrange: Color { Color(red: 0.95, green: 0.62, blue: 0.20) }
}

/// Small observable flag used instead of @State (unavailable without the
/// SwiftUI macro plugin in this toolchain).
final class UIFlag: ObservableObject {
    @Published var value: Bool
    init(_ value: Bool = false) { self.value = value }
}

final class UIValue<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    private var theme: Theme { Theme.current }
    var padding: CGFloat = CardPadding.regular
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(theme.cardStroke, lineWidth: 1)
                    )
            )
    }
}

struct SectionLabel: View {
    private var theme: Theme { Theme.current }
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.label.weight(.semibold))
            .foregroundColor(theme.textTertiary)
            .padding(.leading, 4)
    }
}

struct IconBadge: View {
    private var theme: Theme { Theme.current }
    let symbol: String
    var color: Color? = nil
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(Glyph.row)
            .foregroundColor(color ?? theme.textPrimary)
            .frame(width: size + 6, height: size)
    }
}

struct HelpDot: View {
    private var theme: Theme { Theme.current }
    var text: String
    @StateObject private var flag = UIFlag()

    var body: some View {
        Button {
            flag.value.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(Glyph.row)
                .foregroundColor(theme.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $flag.value, arrowEdge: .bottom) {
            Text(text)
                .font(Typography.body)
                .foregroundColor(.primary)
                .padding(Spacing.m)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ToggleRow: View {
    private var theme: Theme { Theme.current }
    let symbol: String
    let title: String
    var help: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            IconBadge(symbol: symbol)
            Text(title)
                .font(Typography.headline)
                .foregroundColor(disabled ? theme.textTertiary : theme.textPrimary)
            if let help { HelpDot(text: help) }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
                .disabled(disabled)
                .scaleEffect(0.82)
                .frame(width: 42, height: 22)
        }
        .frame(height: 30)
    }
}

struct PickerRow<T: Hashable>: View {
    private var theme: Theme { Theme.current }
    let symbol: String
    let title: String
    var help: String? = nil
    @Binding var selection: T
    let options: [(T, String)]
    var width: CGFloat = 200

    var body: some View {
        HStack(spacing: Spacing.s) {
            IconBadge(symbol: symbol)
            Text(title)
                .font(Typography.headline)
                .foregroundColor(theme.textPrimary)
            if let help { HelpDot(text: help) }
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { option in
                    Text(option.element.1).tag(option.element.0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: width)
        }
        .frame(height: 30)
    }
}

struct ChipButton: View {
    private var theme: Theme { Theme.current }
    let title: String
    var symbol: String? = nil
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol).font(Glyph.row)
                }
                Text(title).font(Typography.headline)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundColor(selected ? .white : theme.textPrimary)
            .background(
                Capsule().fill(selected ? theme.accent : theme.innerControl)
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SmallActionButton: View {
    private var theme: Theme { Theme.current }
    let title: String
    var symbol: String? = nil
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol { Image(systemName: symbol).font(Glyph.row) }
                Text(title).font(Typography.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
            .foregroundColor(destructive ? Color(red: 1, green: 0.27, blue: 0.23) : theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

struct ValueStepper: View {
    private var theme: Theme { Theme.current }
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var step = 5
    var suffix = "%"

    var body: some View {
        HStack(spacing: 0) {
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus")
                    .font(Glyph.inline.weight(.semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)

            Text("\(value)")
                .font(Typography.headline.monospacedDigit())
                .frame(minWidth: 30)
                .foregroundColor(theme.textPrimary)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .font(Glyph.inline.weight(.semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)

            Text(suffix)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
                .padding(.trailing, 8)
        }
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
    }
}
