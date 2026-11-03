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
            Color.clear.frame(height: 36)

            ForEach(Array(Panel.allCases.enumerated()), id: \.offset) { item in
                let panel = item.element
                if let category = panel.category, category != previousCategory(item.offset) {
                    Text(category)
                        .font(.system(size: 11))
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
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 18)
                        Text(panel.title)
                            .font(.system(size: 12.5))
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
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundColor(theme.accent)
                    .sheet(isPresented: $showingUpdates.value) { UpdateSheet() }
                    Button(t("立即更新")) { updater.checkForUpdates() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(theme.textSecondary)
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                    Text(t("开发者 Steven Yang"))
                        .font(.system(size: 9))
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
                            .font(.system(size: 11).monospacedDigit())
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
                .font(.system(size: 12, weight: .medium))
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
            case .calibration: CalibrationPage()
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
