//
//  RootView.swift
//  Sidebar + detail layout.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updater = SparkleUpdater.shared
    @StateObject private var showingUpdates = UIFlag()
    /// Which row the pointer is over. `nil` is the resting state, so hovering a
    /// second row cannot leave the first one lit.
    @StateObject private var hovered = UIValue<Panel?>(nil)
    private var theme: Theme { Theme.current }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.divider).frame(width: 1)
            // Attached to the child, not the HStack: two .sheet modifiers on the
            // same view are unreliable before macOS 13.
            content
                .sheet(isPresented: $state.showingCalibrationMode) {
                    CalibrationModeSheet()
                        .environmentObject(state)
                }
        }
        .background(theme.windowBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $state.showFirstRunHelperPrompt) {
            FirstRunHelperSheet()
                .environmentObject(state)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window uses .fullSizeContentView, so SwiftUI already insets
            // this stack by the titlebar height (32 pt on this Mac, measured).
            // The old fixed 36 pt spacer sat on top of that inset and pushed the
            // first item 36 pt below the traffic lights; 8 pt is breathing room,
            // not a second copy of the titlebar.
            Color.clear.frame(height: Spacing.s)

            ForEach(Array(Panel.allCases.enumerated()), id: \.offset) { item in
                let panel = item.element
                if let category = panel.category, category != previousCategory(item.offset) {
                    Text(category)
                        .font(Typography.label.weight(.semibold))
                        .tracking(0.6)
                        .foregroundColor(theme.textTertiary)
                        .padding(.leading, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                }
                Button {
                    withAnimation(Motion.panel) {
                        state.selectedPanel = panel
                    }
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: panel.symbol)
                            .font(Glyph.row)
                            .frame(width: 18)
                        Text(panel.title)
                            .font(Typography.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(state.selectedPanel == panel ? theme.accent : theme.textPrimary)
                    .padding(.leading, 11)
                    .padding(.trailing, 9)
                    .frame(height: 30)
                }
                .buttonStyle(SidebarRowStyle(selected: state.selectedPanel == panel,
                                             hovered: hovered.value == panel))
                // The row style is custom, so the system ring is gone. Without
                // this, tabbing through the sidebar moved an invisible cursor.
                .focusRing(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(state.selectedPanel == panel ? [.isSelected] : [])
                .onHover { inside in
                    if inside {
                        hovered.value = panel
                    } else if hovered.value == panel {
                        hovered.value = nil
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
            }

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 240)
        .background(theme.sidebarBackground)
        // The sidebar is 0.005 lighter than the window in light mode — 1.04:1,
        // which is no boundary at all. Deepening the fill cannot fix it without
        // turning the sidebar grey, so draw the edge instead: one hairline is
        // what macOS sidebars use and it survives both appearances.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.cardStroke)
                .frame(width: 1)
        }
    }

    /// Company, author, then version and the update entry on a line of their
    /// own. All three used to share one 28 pt band: the credit was centred on
    /// the sidebar rather than between the two controls beside it, and the
    /// version sat at the far right with nothing to do with the name it was
    /// level with.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                circleButton("power", label: t("退出 InfiniCal")) { NSApp.terminate(nil) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Infinity Computer")
                        .font(Typography.micro)
                        .foregroundColor(theme.textSecondary)
                    Text(t("开发者 Steven Yang"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            updateCapsule
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.m)
    }

    /// Version on the left, update entry on the right, one hit target. When a
    /// release is waiting the capsule turns into the notice itself instead of
    /// stacking a second line above the credit.
    private var updateCapsule: some View {
        let available = updater.availableVersion
        return Button {
            showingUpdates.value = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("v\(appVersion)")
                    .font(Typography.caption.monospacedDigit())
                Spacer(minLength: Spacing.xs)
                if let available {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill").font(Glyph.inline)
                        Text(tf("发现新版本 {p}", available))
                            .font(Typography.micro.weight(.medium))
                    }
                } else {
                    Text(t("检查更新")).font(Typography.micro)
                }
            }
            .foregroundColor(available == nil ? theme.textSecondary : .white)
            .padding(.horizontal, Spacing.s + Spacing.xxs)
            .frame(height: 24)
            .background(Capsule().fill(available == nil ? theme.innerControl : theme.accent))
        }
        .buttonStyle(.plain)
        .help(available == nil ? t("检查更新") : tf("发现新版本 {p}", available ?? ""))
        .sheet(isPresented: $showingUpdates.value) { UpdateSheet() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func previousCategory(_ index: Int) -> String? {
        guard index > 0, index - 1 < Panel.allCases.count else { return nil }
        return Panel.allCases[index - 1].category
    }

    private func circleButton(_ symbol: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Glyph.row)
                .foregroundColor(theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)))
                .overlay(Circle().strokeBorder(theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusRing(Circle())
        // Icon-only: "power" is not a label, and VoiceOver had nothing to say.
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch state.selectedPanel {
            case .dashboard: DashboardView()
            case .chargeControl: ChargeControlView()
            case .calibration: CalibrationPanel()
            case .fanControl: FanControlPage()
            case .sleep: SleepEnergyView()
            case .history: HistoryView()
            case .schedule: ScheduleView()
            case .other: OtherView()
            }
        }
        .id(state.selectedPanel)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.windowBackground)
    }
}

/// Three states on one row: resting, pointer-over, selected.
///
/// The old row only had two, and the selected one leaned on 9 % white plus the
/// accent text — on a 11.5 % sidebar that fill was barely above the row's own
/// background. A 3 pt accent bar at the leading edge carries the selection now,
/// so it survives being glanced at rather than read, and hover gets a fill of
/// its own so the pointer has something to say before you click. Held is a
/// deeper fill rather than a fade — see `pressedSidebar`.
private struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    var hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme.current
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(fill(theme, pressed: configuration.isPressed))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 3)
                }
            }
    }

    private func fill(_ theme: Theme, pressed: Bool) -> Color {
        if pressed { return theme.pressedSidebar }
        if selected { return theme.selectedSidebar }
        return hovered ? theme.hoverBackground : Color.clear
    }
}
