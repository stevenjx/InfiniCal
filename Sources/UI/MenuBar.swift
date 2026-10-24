//
//  MenuBar.swift
//  Menu bar presence.
//
//  The app runs with `.accessory`, so it has no Dock icon and no Cmd-Tab entry.
//  Without a status item, closing the window left the process running with no
//  way back to it. This is that way back — and the place to read the battery
//  without opening a 1080 × 720 window.
//

import AppKit
import SwiftUI
import Combine

final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state = AppState.shared
    private let openWindow: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
        observeState()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Debug entry point (`--menubar`): open the popover without a click, the
    /// same way `--panel` opens a page without navigating.
    func showPopover() {
        guard !popover.isShown else { return }
        togglePopover()
    }

    // MARK: - Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        updateButton()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let root = MenuBarPanel(openWindow: openWindow).environmentObject(state)
        let hosting = NSHostingController(rootView: root)
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        popover.contentSize = (fitted.width > 0 && fitted.height > 0)
            ? fitted
            : NSSize(width: 300, height: 340)
        popover.contentViewController = hosting
    }

    private func observeState() {
        state.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        state.$chargeState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let snapshot = state.snapshot
        guard snapshot.isPresent else {
            button.image = NSImage(systemSymbolName: "battery.0", accessibilityDescription: t("无电池"))
            button.image?.isTemplate = true
            button.title = " —"
            button.toolTip = t("未检测到电池")
            return
        }
        let percent = snapshot.percentage
        button.image = NSImage(systemSymbolName: symbolName(percent: percent, charging: snapshot.isCharging),
                               accessibilityDescription: tf("电池 {p}%", "\(percent)"))
        button.image?.isTemplate = true
        button.title = " \(percent)%"
        button.toolTip = tf("{p} · 限制 {p}%", state.chargeState.title, "\(state.chargeVal)")
    }

    private func symbolName(percent: Int, charging: Bool) -> String {
        if charging, percent >= 95 { return "battery.100.bolt" }
        switch percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: - Interaction

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown { closePopover(); return }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item(t("打开 InfiniCal"), #selector(openMainWindow)))
        menu.addItem(.separator())
        menu.addItem(item(t("一次性充满"), #selector(topUp)))
        menu.addItem(item(t("暂停充电"), #selector(pauseCharging)))
        menu.addItem(item(t("充电限制设为 80%"), #selector(setLimit80)))
        menu.addItem(.separator())
        menu.addItem(item(t("风扇恢复自动"), #selector(fanAuto)))
        menu.addItem(.separator())
        menu.addItem(item(t("退出 InfiniCal"), #selector(quit)))
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        closePopover()
        openWindow()
    }

    @objc private func topUp() { state.topUp() }
    @objc private func pauseCharging() { state.pauseCharging() }
    @objc private func setLimit80() { state.chargeVal = 80 }
    @objc private func fanAuto() { FanController.shared.setAllAuto() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Popover content

struct MenuBarPanel: View {

    @EnvironmentObject private var state: AppState
    @ObservedObject private var fans = FanController.shared
    var openWindow: () -> Void

    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            actions
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(theme.windowBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { fans.beginMonitoring() }
        .onDisappear { fans.endMonitoring() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(theme.divider, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, Double(state.snapshot.percentage) / 100)))
                    .stroke(theme.chartGreen, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(state.snapshot.isPresent ? "\(state.snapshot.percentage)" : "—")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.textPrimary)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.chargeState.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(summaryLine)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var metrics: some View {
        VStack(spacing: 6) {
            metricRow("thermometer.medium", t("电池温度"), temperatureText)
            metricRow("fanblades", t("风扇"), fanText)
            metricRow("powerplug", t("适配器"), adapterText)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                SmallActionButton(title: t("充满"), symbol: "bolt.fill") { state.topUp() }
                SmallActionButton(title: t("暂停"), symbol: "pause.fill") { state.pauseCharging() }
            }
            HStack(spacing: 6) {
                SmallActionButton(title: t("设为 80%"), symbol: "battery.75") { state.chargeVal = 80 }
                SmallActionButton(title: t("风扇自动"), symbol: "fanblades") {
                    FanController.shared.setAllAuto()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow()
            } label: {
                Text(t("打开 InfiniCal")).font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(t("退出")).font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)
        }
    }

    private func metricRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundColor(theme.textSecondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(theme.textPrimary)
        }
    }

    // MARK: - Text

    private var summaryLine: String {
        if let restore = state.topUpRestoreLimit {
            return tf("一次性充满中 · 完成后恢复 {p}%", "\(restore)")
        }
        guard state.snapshot.isPresent else { return t("未检测到电池") }
        return tf("充电限制 {p}%", "\(state.chargeVal)")
    }

    private var temperatureText: String {
        let temperature = state.snapshot.temperature
        return temperature > 0 ? String(format: "%.1f °C", temperature) : "--"
    }

    private var fanText: String {
        let fans = self.fans.fans
        guard let first = fans.first else { return t("无风扇") }
        if fans.count == 1 { return "\(first.currentRPM) RPM" }
        let average = fans.map { $0.currentRPM }.reduce(0, +) / fans.count
        return "\(average) RPM"
    }

    private var adapterText: String {
        let snapshot = state.snapshot
        guard snapshot.isPluggedIn else { return t("未连接") }
        let watts = snapshot.adapter.power > 0.05 ? snapshot.adapter.power : Double(snapshot.adapter.watts)
        return watts > 0.05 ? String(format: "%.0f W", watts) : t("已连接")
    }
}
