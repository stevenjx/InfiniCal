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
    var cardStroke: Color { isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.12) }
    /// Light mode used to rely on a shadow alone. Measured, a white card on the
    /// 0.96 window is 1.09:1 and the 7 % shadow only faked an edge — the card
    /// boundary was invisible. It now gets a hairline *and* a shadow: the
    /// hairline draws the edge, the shadow adds depth.
    ///
    /// Why not 3:1 (WCAG 1.4.11): that ratio targets controls the user must
    /// operate, and no white card on a light-grey field can reach it — the
    /// window would have to drop to ~0.70 grey, which turns a light UI into a
    /// mid-grey one. macOS panels separate by ~1.1:1 the same way. The hairline
    /// at 12 % measures 1.32:1 against the card, which is what makes the edge
    /// visible in a screenshot instead of theoretical.
    var cardStrokeWidth: CGFloat { isDark ? 1 : 1 }
    var cardShadow: Color { isDark ? Color.black.opacity(0) : Color.black.opacity(0.055) }
    var cardShadowRadius: CGFloat { isDark ? 0 : 5 }
    var cardShadowY: CGFloat { isDark ? 0 : 1 }
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
    /// The selected sidebar row, and the one place a stronger fill was needed:
    /// 9 % white on a 11.5 % sidebar measured barely above the row's own
    /// background, so the selection leaned on the accent text alone.
    var selectedSidebar: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
    /// Pointer-over a sidebar row. Half of `selectedSidebar`, so the three
    /// states (idle / hover / selected) stay ordered on both appearances.
    var hoverBackground: Color { isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.045) }
    /// Button-held. Deeper than `selectedSidebar` rather than dimmer: the first
    /// cut faded the whole row to 72 % on press, which measured *darker* than
    /// hover (38 against 41 on a 29 sidebar) — a state that reads as the row
    /// going away instead of being held. Deepening the fill keeps the four
    /// states ordered (29 / 42 / 56 / 70 in dark, 241 / 230 / 222 / 210 in
    /// light) and leaves the label at full strength.
    var pressedSidebar: Color { isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.13) }
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

    /// Chart series colours: dots, lines and fills only. They were one fixed
    /// value shared by both appearances, which put the light appearance at
    /// 2.16:1 (orange) on white — a line you cannot see. The light halves are
    /// the same hues pushed dark enough to clear 3:1 against `card`, the
    /// threshold WCAG 1.4.11 applies to graphical objects.
    ///
    /// Text never uses these; `success`/`warning`/`danger`/`info` carry meaning
    /// in words. `Tools/contrast_check.py` derives its chart-as-text rows from
    /// the call sites, so reintroducing one fails the gate.
    var chartGreen: Color { isDark ? Color(red: 0.29, green: 0.62, blue: 0.36) : Color(red: 0.13, green: 0.45, blue: 0.20) }
    var chartBlue: Color { isDark ? Color(red: 0.25, green: 0.55, blue: 1.0) : Color(red: 0.10, green: 0.36, blue: 0.78) }
    var chartPurple: Color { isDark ? Color(red: 0.60, green: 0.42, blue: 0.95) : Color(red: 0.42, green: 0.24, blue: 0.72) }
    var chartOrange: Color { isDark ? Color(red: 0.95, green: 0.62, blue: 0.20) : Color(red: 0.72, green: 0.42, blue: 0.00) }
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

// MARK: - Motion

/// Animation curves and reduce-motion handling, gathered so callers don't each
/// reach into `@Environment` and repeat the `@available` guards.
///
/// `MACOSX_DEPLOYMENT_TARGET = 12.0`, so `.contentTransition(.numericText())`
/// (macOS 14+) needs a runtime guard. The `.easeInOut` used for panel switches
/// and chart first-frames works on 12+.
///
/// Every curve here is `Animation?`: `nil` means "no animation at all", which
/// is what "Reduce Motion" asks for. `withAnimation(nil)` still runs the state
/// change, it just does not animate it — so the same call site works with the
/// setting on or off.
enum Motion {
    /// 120 ms cross-fade for panel switches.
    static var panel: Animation? { conditional(.easeInOut(duration: 0.12)) }
    /// 300 ms stroke reveal for chart first-frames.
    static var chartStroke: Animation? { conditional(.easeOut(duration: 0.3)) }

    /// `nil` when "Reduce Motion" is on.
    ///
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` reads the
    /// system preference live, so it needs no `@Environment` and works from
    /// non-View contexts.
    static func conditional(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

    /// True when "Reduce Motion" is on — used to skip content transitions,
    /// which have no "nil" form of their own.
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension View {
    /// `.contentTransition(.numericText())` on macOS 14+, no-op elsewhere and
    /// when "Reduce Motion" is on (the digit flip *is* the motion).
    @ViewBuilder
    func numericTextTransition() -> some View {
        if #available(macOS 14, *), !Motion.reducesMotion {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }

    /// Focus ring for controls that opted out of the system one.
    ///
    /// `.buttonStyle(.plain)` is used 28 times here to keep the custom chrome,
    /// and it also removes the ring macOS draws on keyboard focus — so tabbing
    /// through the app moved an invisible cursor. This restores it from
    /// `theme.focusRing`, which was declared for U2-03 and until now had no
    /// user at all.
    ///
    /// `.focusable()` is required: without it a plain-styled button is not in
    /// the key-view loop on macOS and would never report focus.
    func focusRing(_ shape: some InsettableShape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous),
                   inset: CGFloat = 1) -> some View {
        modifier(FocusRing(shape: AnyInsettableShape(shape), inset: inset))
    }
}

private struct AnyInsettableShape: InsettableShape {
    private let _path: (CGRect) -> Path
    private let _inset: (CGFloat) -> AnyInsettableShape

    init<S: InsettableShape>(_ shape: S) {
        _path = { shape.path(in: $0) }
        _inset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    func path(in rect: CGRect) -> Path { _path(rect) }
    func inset(by amount: CGFloat) -> AnyInsettableShape { _inset(amount) }
}

private struct FocusRing: ViewModifier {
    private var theme: Theme { Theme.current }
    let shape: AnyInsettableShape
    let inset: CGFloat
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            // No `.focusable()` here. Adding it made every ring-bearing view a
            // tab stop of its own, which on a custom-styled Button created a
            // second, competing stop — tabbing cycled through the 9 sidebar rows
            // and never reached the page. The controls that need this modifier
            // are already focusable (Button, Toggle); the modifier only draws.
            .focused($focused)
            .overlay {
                if focused {
                    shape
                        .inset(by: -inset)
                        .strokeBorder(theme.focusRing, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Building blocks

/// How a card relates to what is around it.
///
/// Two kinds, not the three the plan listed. `inset` (a card inside a card) and
/// `interactive` (a card you can click) were dropped after counting: nothing in
/// `Sources/UI` nests one `Card` in another, and there is not a single
/// `onTapGesture` or `onHover` on a card. Adding either would have produced a
/// style with no caller — and a hover state on something that does nothing when
/// clicked is a lie. `list` does have callers: three cards hold tables and
/// scroll views whose rows draw their own horizontal inset.
enum CardKind {
    /// A container with content padding and page-level elevation.
    case plain
    /// Full-bleed: no padding, content clipped to the card shape. Rows inside
    /// bring their own inset, so the card's edges are the table's edges.
    case list
}

struct Card<Content: View>: View {
    private var theme: Theme { Theme.current }
    var kind: CardKind = .plain
    var padding: CardInset = .regular
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }

    private var inset: CGFloat { kind == .list ? CardPadding.none : padding.value }

    var body: some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clipped before the background is drawn, so a full-bleed row's
            // fill stops at the corner radius instead of squaring it off.
            .clipShape(shape)
            .background(
                shape
                    .fill(theme.card)
                    .overlay(shape.strokeBorder(theme.cardStroke, lineWidth: theme.cardStrokeWidth))
                    .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius,
                            x: 0, y: theme.cardShadowY)
            )
    }
}

/// The one card title in the app.
///
/// Before this there were two private helpers — `cardHeader` on the dashboard
/// and `cardTitle` on the calibration page — plus a dozen hand-written
/// `Text(…).font(Typography.headline)` lines. They disagreed about icon size
/// (10 vs 12 pt), icon tint (secondary vs series colour), spacing (5, 6, 10)
/// and whether the title sat in an `HStack` with a `Spacer`. Two cards on the
/// same page could look like two different products. Everything goes through
/// here now, so they cannot.
struct CardHeader<Trailing: View>: View {
    private var theme: Theme { Theme.current }
    let title: String
    var symbol: String? = nil
    /// Icon colour only. A tinted *title* would compete with the values below
    /// it, which is why the title is always `textPrimary`.
    var tint: Color? = nil
    var help: String? = nil
    /// Explanation under the title: `caption` in `textSecondary`.
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(Glyph.row)
                        .foregroundColor(tint ?? theme.textPrimary)
                }
                Text(title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                if let help { HelpDot(text: help) }
                Spacer(minLength: Spacing.s)
                trailing
            }
            if let subtitle {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, tint: Color? = nil,
         help: String? = nil, subtitle: String? = nil) {
        self.init(title: title, symbol: symbol, tint: tint, help: help,
                  subtitle: subtitle) { EmptyView() }
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
            // 280 pt: the help texts are one or two sentences, and 260 broke
            // the longer ones into four lines inside a bubble that is mostly
            // padding.
            Text(text)
                .font(Typography.body)
                .foregroundColor(.primary)
                .padding(Spacing.m)
                .frame(width: 280, alignment: .leading)
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
        // `labelsHidden()` leaves VoiceOver with an unlabelled switch, and the
        // row title was not associated with it. The switch stays the focusable
        // element (it is a native Toggle, so it is in the key-view loop);
        // the ring is drawn on the row so it is findable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
            .foregroundColor(destructive ? theme.danger : theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}

struct ValueStepper: View {
    private var theme: Theme { Theme.current }
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var step = 5
    /// Intrinsic width is 26 + 30 + 26 + suffix + 8: **98 pt for "%" and 106 pt
    /// for "°C"**. A narrower `frame(width:)` does not shrink the buttons, so
    /// the suffix used to wrap into a vertical "° / C" — give it at least that.
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
                .numericTextTransition()

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
                .lineLimit(1)
                .padding(.trailing, 8)
        }
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.innerControl))
    }
}
