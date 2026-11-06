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
    /// Snapshot last drawn into the status item. The battery level only moves
    /// every few minutes, but the state object publishes every 2 s; without this
    /// the button allocates a fresh NSImage on every tick.
    private var lastButtonKey: String?

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
        let discharging = snapshot.instantAmperage < -0.05 || snapshot.amperage < -0.05
        let key = "\(snapshot.isPresent)-\(snapshot.percentage)-\(snapshot.isCharging)-\(snapshot.isPluggedIn)-\(discharging)-\(state.chargeState)-\(state.chargeVal)-\(L10n.isChinese)"
        if let last = lastButtonKey, last == key { return }
        lastButtonKey = key
        guard snapshot.isPresent else {
            button.image = batteryImage("battery.0", description: t("无电池"))
            button.attributedTitle = statusTitle(" —")
            button.toolTip = t("未检测到电池")
            return
        }
        let percent = snapshot.percentage
        button.image = stateBatteryImage(mode: discharging ? "discharge" : (snapshot.isCharging ? "charge" : "hold"))
        button.attributedTitle = statusTitle(" \(percent)%")
        button.toolTip = tf("{p} · 限制 {p}%", state.chargeState.title, "\(state.chargeVal)")
    }

    /// Status bar text, slightly larger than the system default so it reads at
    /// a glance without outweighing the icon.
    private func statusTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
            .baselineOffset: 0.5
        ])
    }

    /// A symbol sized for the status bar.
    ///
    /// `withSymbolConfiguration` leaves `size` at the symbol's natural value
    /// (22×11 for `battery.*`), and the status item draws at `size` — which is
    /// why the icon read as a speck next to the 11 pt title. The height is set
    /// here instead, keeping the glyph's aspect ratio.
    private func batteryImage(_ name: String, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        let targetHeight: CGFloat = 16
        if image.size.height > 0 {
            let ratio = targetHeight / image.size.height
            image.size = NSSize(width: (image.size.width * ratio).rounded(), height: targetHeight)
        }
        return image
    }

    /// Three vector template glyphs share the same battery outline.
    private func stateBatteryImage(mode: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 27, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 23, height: 12), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.4
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 25, y: 6, width: 2, height: 4), xRadius: 0.5, yRadius: 0.5).fill()
            if mode == "charge" {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 14, y: 13)); bolt.line(to: NSPoint(x: 9, y: 7))
                bolt.line(to: NSPoint(x: 12, y: 7)); bolt.line(to: NSPoint(x: 11, y: 3))
                bolt.line(to: NSPoint(x: 17, y: 9)); bolt.line(to: NSPoint(x: 14, y: 9))
                bolt.close(); bolt.fill()
            } else if mode == "discharge" {
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: 12.5, y: 12)); arrow.line(to: NSPoint(x: 12.5, y: 5))
                arrow.move(to: NSPoint(x: 9, y: 8)); arrow.line(to: NSPoint(x: 12.5, y: 4.5)); arrow.line(to: NSPoint(x: 16, y: 8))
                arrow.lineWidth = 1.6; arrow.stroke()
            } else {
                NSBezierPath(rect: NSRect(x: 9, y: 5, width: 2.5, height: 6)).fill()
                NSBezierPath(rect: NSRect(x: 14, y: 5, width: 2.5, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = t(mode == "charge" ? "充电中" : (mode == "discharge" ? "放电中" : "停止充电"))
        return image
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
        NSApp.activateInFront()
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
    @objc private func setLimit80() { state.userSetLimit(80) }
    @objc private func fanAuto() { FanController.shared.setAllAuto() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Popover content

struct MenuBarPanel: View {

    @EnvironmentObject private var state: AppState
    @ObservedObject private var fans = FanController.shared
    @ObservedObject private var alerts = AnomalyAlerts.shared
    @StateObject private var exportMessage = UIValue<String?>(nil)
    @StateObject private var showUpdates = UIFlag()
    var openWindow: () -> Void

    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            controlSummary
            Button(t("检查更新")) { showUpdates.value = true }
                .buttonStyle(.plain).font(Typography.caption).foregroundColor(theme.accent)
            actions
            Button(t("导出当前诊断")) { exportDiagnostics() }
                .buttonStyle(.plain).font(Typography.caption).foregroundColor(theme.accent)
            if let message = exportMessage.value {
                Text(message).font(Typography.caption).foregroundColor(theme.textSecondary)
            }
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(theme.windowBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $showUpdates.value) { UpdateSheet() }
        .onAppear {
            fans.beginMonitoring()
            Task { @MainActor in SparkleUpdater.shared.checkInBackground() }
        }
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
                    .font(Typography.title.monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                    .numericTextTransition()
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.chargeState.title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Text(summaryLine)
                    .font(Typography.caption)
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
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.card))
    }

    private var controlSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.capabilities.strategy.title)
                .font(Typography.label)
            Text(state.capabilities.summary)
                .font(Typography.caption).foregroundColor(theme.textSecondary)
            Text(tf("策略：{p}", policyText))
                .font(Typography.caption)
            Text(tf("请求上限 {p}% · 实际电量 {p}%", "\(state.chargeVal)", "\(state.snapshot.percentage)"))
                .font(Typography.caption)
            Text(actualText).font(Typography.caption)
            Text(tf("采样时间：{p}", state.snapshot.timestamp.formatted(date: .omitted, time: .standard)))
                .font(Typography.caption).foregroundColor(theme.textSecondary)
            if !state.statusNote.isEmpty {
                Text(state.statusNote).font(Typography.caption).foregroundColor(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !alerts.events.isEmpty {
                Text(tf("异常记录：{p}（历史页查看）", "\(alerts.events.count)"))
                    .font(Typography.caption).foregroundColor(theme.warning)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(theme.card))
    }

    private var policyText: String {
        if CalibrationEngine.shared.needsRecovery { return t("等待校准恢复") }
        if CalibrationEngine.shared.isRunning { return CalibrationEngine.shared.phase.title }
        if state.topUpRestoreLimit != nil { return t("一次性充满") }
        if state.userPaused { return t("手动暂停") }
        if state.automaticDischarge { return t("自动放电") }
        if state.sailingMode { return tf("航海模式：{p}%–{p}%", "\(max(0, state.chargeVal - state.sailingLevel))", "\(state.chargeVal)") }
        return t("充电上限控制")
    }

    private var actualText: String {
        let sample = state.snapshot
        guard sample.isPresent else { return t("未检测到电池") }
        let current = sample.instantAmperage
        let flow = current < -0.05 ? t("放电中") : (current > 0.05 ? t("充电中") : t("未检测到明显电流"))
        return flow + String(format: " · %.3f A · %.2f V", current, sample.voltage)
    }

    private func exportDiagnostics() {
        // Opening the save dialog makes this an explicit user-initiated read.
        let report = HardwareDiagnosticReport.capture()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InfiniCal-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
            exportMessage.value = t("诊断已导出（不含序列号）")
        } catch { exportMessage.value = error.localizedDescription }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                SmallActionButton(title: t("充满"), symbol: "bolt.fill") { state.topUp() }
                SmallActionButton(title: t("暂停"), symbol: "pause.fill") { state.pauseCharging() }
            }
            HStack(spacing: 6) {
                SmallActionButton(title: t("设为 80%"), symbol: "battery.75") { state.userSetLimit(80) }
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
                Text(t("打开 InfiniCal")).font(Typography.headline)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(t("退出")).font(Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textSecondary)
        }
    }

    private func metricRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(Glyph.inline)
                .foregroundColor(theme.textSecondary)
                .frame(width: 14)
            Text(title)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
            Spacer(minLength: 6)
            Text(value)
                .font(Typography.label.monospacedDigit())
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
        if snapshot.adapter.hasMeasuredInput, snapshot.adapter.power > 0.05 {
            return String(format: "%.0f W", snapshot.adapter.power)
        }
        // Intel exposes no measured input. The rated wattage is a spec, not a
        // draw, so it is printed as an upper bound instead of being passed off
        // as the current power.
        return snapshot.adapter.watts > 0 ? String(format: "≤%.0f W", Double(snapshot.adapter.watts))
                                          : t("已连接")
    }
}
