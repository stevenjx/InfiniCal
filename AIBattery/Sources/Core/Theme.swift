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
    var innerControl: Color { isDark ? Color(red: 0.235, green: 0.235, blue: 0.245) : Color(red: 0.925, green: 0.925, blue: 0.935) }
    var cardStroke: Color { isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.06) }
    var divider: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07) }
    var textPrimary: Color { isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.86) }
    var textSecondary: Color { isDark ? Color.white.opacity(0.52) : Color.black.opacity(0.5) }
    var textTertiary: Color { isDark ? Color.white.opacity(0.34) : Color.black.opacity(0.32) }
    var accent: Color { Color(red: 0.04, green: 0.52, blue: 1.0) }
    var selectedSidebar: Color { isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    var chartGreen: Color { Color(red: 0.29, green: 0.62, blue: 0.36) }
    var chartBlue: Color { Color(red: 0.25, green: 0.55, blue: 1.0) }
    var chartPurple: Color { Color(red: 0.60, green: 0.42, blue: 0.95) }
    var chartOrange: Color { Color(red: 0.95, green: 0.62, blue: 0.20) }

    static func resolve(mode: Int) -> Theme {
        switch mode {
        case 1: return Theme(isDark: false)
        case 2: return Theme(isDark: true)
        default:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return Theme(isDark: dark)
        }
    }
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
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
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
            .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: size * 0.62, weight: .medium))
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
                .font(.system(size: 13))
                .foregroundColor(theme.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $flag.value, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .padding(12)
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
        HStack(spacing: 10) {
            IconBadge(symbol: symbol)
            Text(title)
                .font(.system(size: 13))
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
        HStack(spacing: 10) {
            IconBadge(symbol: symbol)
            Text(title)
                .font(.system(size: 13))
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
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundColor(selected ? .white : theme.textPrimary)
            .background(
                Capsule().fill(selected ? theme.accent : theme.innerControl)
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : theme.cardStroke, lineWidth: 1)
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
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.innerControl))
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
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)

            Text("\(value)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(minWidth: 30)
                .foregroundColor(theme.textPrimary)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)

            Text(suffix)
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)
                .padding(.trailing, 8)
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.innerControl))
    }
}
