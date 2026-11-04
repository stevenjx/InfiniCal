//
//  RootView.swift
//  Sidebar + detail layout.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var updater = SparkleUpdater.shared
    @StateObject private var showingUpdates = UIFlag()
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
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                        .padding(.leading, 12)
                        .padding(.top, item.offset == 1 ? 16 : 14)
                        .padding(.bottom, 4)
                }
                Button {
                    state.selectedPanel = panel
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: panel.symbol)
                            .font(Glyph.row)
                            .frame(width: 18)
                        Text(panel.title)
                            .font(Typography.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(state.selectedPanel == panel ? theme.accent : theme.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.selectedPanel == panel ? theme.selectedSidebar : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
            }

            Spacer(minLength: 0)

            if let version = updater.availableVersion {
                VStack(alignment: .leading, spacing: 6) {
                    Button { showingUpdates.value = true } label: {
                        Label(tf("发现新版本 {p}", version), systemImage: "arrow.down.circle.fill")
                            .font(Typography.label)
                    }
                    .buttonStyle(.plain).foregroundColor(theme.info)
                    .sheet(isPresented: $showingUpdates.value) { UpdateSheet() }
                    Button(t("立即更新")) { updater.checkForUpdates() }
                        .buttonStyle(.plain).font(Typography.caption).foregroundColor(theme.textSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.selectedSidebar))
                .padding(.horizontal, 12).padding(.bottom, 10)
            }

            ZStack {
                // Centred in the sidebar regardless of what sits at either end.
                VStack(spacing: 1) {
                    Text("Infinity Computer")
                        .font(Typography.micro)
                        .foregroundColor(theme.textSecondary)
                    Text(t("开发者 Steven Yang"))
                        .font(Typography.micro)
                        .foregroundColor(theme.textTertiary)
                }
                .fixedSize()

                HStack(spacing: 12) {
                    circleButton("power") { NSApp.terminate(nil) }
                    Spacer(minLength: 0)
                    Button {
                        openReleasePage()
                    } label: {
                        Text("v\(appVersion)")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundColor(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(t("在 GitHub 上查看发布说明"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 240)
        .background(theme.sidebarBackground)
    }

    private func openReleasePage() {
        guard let url = URL(string: "https://github.com/stevenjx/InfiniCal/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func previousCategory(_ index: Int) -> String? {
        guard index > 0, index - 1 < Panel.allCases.count else { return nil }
        return Panel.allCases[index - 1].category
    }

    private func circleButton(_ symbol: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Glyph.row)
                .foregroundColor(highlighted ? theme.accent : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)))
                .overlay(Circle().strokeBorder(theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.windowBackground)
    }
}
