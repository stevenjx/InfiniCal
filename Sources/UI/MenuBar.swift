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
//
//  The window is a report; this is a control surface. That is why the order is
//  different from the dashboard: state, then the two levers, then links. The
//  strategy narrative (backend, policy, request vs observed, sample time) is
//  still here, but folded away — it used to be five lines of body-size text
//  between the metrics and the buttons, which made a 300 pt popover read like a
//  log file.

struct MenuBarPanel: View {

    @EnvironmentObject private var state: AppState
    @ObservedObject private var fans = FanController.shared
    @ObservedObject private var alerts = AnomalyAlerts.shared
    @StateObject private var exportMessage = UIValue<String?>(nil)
    @StateObject private var showUpdates = UIFlag()
    @StateObject private var showDetails = UIFlag(false)
    var openWindow: () -> Void

    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            metrics
            notice
            controls
            links
            footer
        }
        .padding(14)
        .frame(width: 316)
        .background(theme.windowBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $showUpdates.value) { UpdateSheet() }
        .onAppear {
            fans.beginMonitoring()
            Task { @MainActor in SparkleUpdater.shared.checkInBackground() }
        }
        .onDisappear { fans.endMonitoring() }
    }

    // MARK: State

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(theme.divider, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, Double(state.snapshot.percentage) / 100)))
                    .stroke(ringTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(state.snapshot.isPresent ? "\(state.snapshot.percentage)" : "—")
                    .font(Typography.title.monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                    .numericTextTransition()
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.chargeState.title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                Text(summaryLine)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { openWindow() } label: {
                Image(systemName: "macwindow").font(Glyph.row)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.textTertiary)
            .help(t("打开 InfiniCal"))
        }
    }

    /// One colour per situation. A green ring on a paused machine read as
    /// "charging fine" when nothing was charging.
    private var ringTint: Color {
        switch state.chargeState {
        case .charging, .full: return theme.success
        case .discharging, .calibrating: return theme.accent
        case .paused: return theme.textSecondary
        case .noBattery: return theme.danger
        case .noAdapter: return theme.textTertiary
        }
    }

    /// Three figures as a row of tiles rather than three label/value lines: at
    /// this width the lines were mostly empty space and the numbers were the
    /// last thing the eye found.
    private var metrics: some View {
        HStack(spacing: 0) {
            tile("thermometer.medium", temperatureText, t("温度"))
            divider
            tile("fanblades", fanText, t("风扇"))
            divider
            tile("powerplug", adapterText, t("电源"))
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.card))
    }

    private var divider: some View {
        Rectangle().fill(theme.divider).frame(width: 1, height: 26)
    }

    private func tile(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(Glyph.inline)
                .foregroundColor(theme.textTertiary)
            Text(value)
                .font(Typography.caption.monospacedDigit())
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(Typography.micro)
                .foregroundColor(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// One line, and only when there is something to say. The full sentence is
    /// in the tooltip; the old card printed all of it, wrapped to four lines.
    @ViewBuilder
    private var notice: some View {
        let message = state.statusNote.isEmpty ? nil : state.statusNote
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(Glyph.inline)
                    .foregroundColor(theme.warning)
                Text(message)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(2)
                    .help(message)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(theme.warning.opacity(0.12)))
        }
    }

    // MARK: Controls

    /// The two things a menu-bar click is usually for: change the ceiling, or
    /// stop charging for a while. Switches, not buttons — a button cannot show
    /// that the machine is already paused.
    private var controls: some View {
        VStack(spacing: 8) {
            limitRow
            toggleRow(symbol: "pause.circle",
                      title: t("暂停充电"),
                      isOn: state.userPaused,
                      help: t("暂停后保持当前电量；关闭开关恢复充电。")) { paused in
                if paused { state.pauseCharging() } else { state.resumeCharging() }
            }
            toggleRow(symbol: "fanblades",
                      title: t("风扇自动"),
                      isOn: !fans.isAnyManual,
                      help: t("关闭后使用你在风扇页设置的固定转速或曲线。"),
                      disabled: !fans.hasFans) { auto in
                if auto { fans.setAllAuto() }
            }
            detailsDisclosure
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.card))
    }

    /// A stepper plus three presets. The old single button hard-coded 80 %,
    /// which is a strange thing to offer on a machine already at 80 %.
    private var limitRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "battery.75")
                    .font(Glyph.inline)
                    .foregroundColor(theme.textTertiary)
                Text(t("充电上限"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Spacer(minLength: 0)
                Text("\(state.effectiveLimit)%")
                    .font(Typography.label.monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                stepper("minus") { state.userSetLimit(max(5, state.chargeVal - 5)) }
                stepper("plus") { state.userSetLimit(min(100, state.chargeVal + 5)) }
            }
            HStack(spacing: 4) {
                ForEach([60, 80, 100], id: \.self) { value in
                    presetChip(value)
                }
                Spacer(minLength: 0)
                if let scenario = state.scenarioResolution {
                    Text(scenario.kind.title)
                        .font(Typography.micro)
                        .foregroundColor(theme.accent)
                        .help(scenario.evidence)
                }
            }
        }
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Glyph.inline.weight(.semibold))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(theme.innerControl))
                .foregroundColor(theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func presetChip(_ value: Int) -> some View {
        let selected = state.chargeVal == value
        return Button {
            state.userSetLimit(value)
        } label: {
            Text("\(value)%")
                .font(Typography.micro.monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? theme.accent.opacity(0.18) : theme.innerControl))
                .foregroundColor(selected ? theme.accent : theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(symbol: String, title: String, isOn: Bool, help: String,
                           disabled: Bool = false,
                           action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(Glyph.inline)
                .foregroundColor(theme.textTertiary)
            Text(title)
                .font(Typography.caption)
                .foregroundColor(theme.textSecondary)
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(theme.accent)
                .disabled(disabled)
        }
        .help(help)
        .opacity(disabled ? 0.45 : 1)
    }

    /// The strategy narrative, folded away. Everything here is worth having on
    /// the day something goes wrong, and none of it is worth a line on a normal
    /// day.
    private var detailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showDetails.value.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showDetails.value ? "chevron.down" : "chevron.right")
                        .font(Glyph.inline.weight(.semibold))
                    Text(t("详细信息"))
                        .font(Typography.micro)
                    Spacer(minLength: 0)
                    if !alerts.events.isEmpty {
                        Text("\(alerts.events.count)")
                            .font(Typography.micro.monospacedDigit())
                            .foregroundColor(theme.warning)
                    }
                }
                .foregroundColor(theme.textTertiary)
            }
            .buttonStyle(.plain)

            if showDetails.value {
                VStack(alignment: .leading, spacing: 2) {
                    detailLine(t("策略"), policyText)
                    detailLine(t("后端"), state.capabilities.strategy.title)
                    detailLine(t("请求上限"), "\(state.chargeVal)%")
                    detailLine(t("实际电量"), "\(state.snapshot.percentage)%")
                    detailLine(t("采样"), state.snapshot.timestamp.formatted(date: .omitted, time: .standard))
                    if !state.statusNote.isEmpty {
                        Text(state.statusNote)
                            .font(Typography.micro)
                            .foregroundColor(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !alerts.events.isEmpty {
                        Text(tf("异常记录 {p} 条，详见历史页", "\(alerts.events.count)"))
                            .font(Typography.micro)
                            .foregroundColor(theme.warning)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundColor(theme.textTertiary)
            Spacer(minLength: 6)
            Text(value)
                .foregroundColor(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Typography.micro)
    }

    // MARK: Links and footer

    private var links: some View {
        HStack(spacing: 10) {
            Button { showUpdates.value = true } label: {
                Text(t("检查更新")).font(Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)

            Button { exportDiagnostics() } label: {
                Text(t("导出诊断")).font(Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accent)

            Spacer(minLength: 0)

            if let message = exportMessage.value {
                Text(message)
                    .font(Typography.micro)
                    .foregroundColor(theme.textTertiary)
                    .lineLimit(1)
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

    // MARK: - Text

    private var summaryLine: String {
        if let restore = state.topUpRestoreLimit {
            return tf("{p}% → 完成后恢复 {p}%", "\(state.effectiveLimit)", "\(restore)")
        }
        guard state.snapshot.isPresent else { return t("未检测到电池") }
        if let scenario = state.scenarioResolution {
            return tf("上限 {p}%（由「{p}」接管）", "\(state.effectiveLimit)", scenario.kind.title)
        }
        return tf("上限 {p}%", "\(state.chargeVal)")
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

    private var temperatureText: String {
        let temperature = state.snapshot.temperature
        return temperature > 0 ? String(format: "%.1f°C", temperature) : "--"
    }

    private var fanText: String {
        let fans = self.fans.fans
        guard let first = fans.first else { return "--" }
        let rpm = fans.count == 1 ? first.currentRPM
                                  : fans.map { $0.currentRPM }.reduce(0, +) / fans.count
        return "\(rpm) RPM"
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
        return snapshot.adapter.watts > 0 ? String(format: "≤%d W", snapshot.adapter.watts)
                                          : t("已连接")
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
            exportMessage.value = t("已导出")
        } catch { exportMessage.value = error.localizedDescription }
    }
}
