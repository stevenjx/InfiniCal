//
//  AppDelegate.swift
//  Window, menu bar item and popover.
//

import AppKit
import SwiftUI
import Combine

struct ThemedRoot: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        RootView()
            .preferredColorScheme(state.theme.isDark ? .dark : .light)
    }
}

struct ThemedPopover: View {
    @EnvironmentObject private var state: AppState
    var openWindow: () -> Void

    var body: some View {
        PopoverView(openWindow: openWindow)
            .preferredColorScheme(state.theme.isDark ? .dark : .light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private let state = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(state.showDockIcon ? .regular : .accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--panel"), index + 1 < CommandLine.arguments.count,
           let panel = Panel(rawValue: CommandLine.arguments[index + 1]) {
            state.selectedPanel = panel
        }
        setupStatusItem()
        if CommandLine.arguments.contains("--popover") {
            showPopoverWindow()
        } else if state.showGUIonStartup {
            showWindow()
        }
        observeState()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.state.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.window?.appearance = NSAppearance(named: self.state.colorMode == 1 ? .aqua : .darkAqua)
            }

        NotificationCenter.default.addObserver(forName: .openPopoverEditMode, object: nil, queue: .main) { [weak self] _ in
            self?.state.selectedPanel = .menuBar
            self?.showWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if state.exitInhibitCharge {
            try? ChargeController.shared.setChargingAllowed(true)
        }
    }

    // MARK: - Window

    func showWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: ThemedRoot().environmentObject(state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered,
                                  defer: false)
            window.title = "AIBattery"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 980, height: 640)
            window.contentView = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: state.colorMode == 1 ? .aqua : .darkAqua)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopoverWindow() {
        let hosting = NSHostingView(rootView: ThemedPopover(openWindow: { [weak self] in self?.showWindow() })
            .environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = NSHostingController(rootView: ThemedPopover(openWindow: { [weak self] in
            self?.popover?.performClose(nil)
            self?.showWindow()
        }).environmentObject(state))
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 660)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 660)
        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        self.popover = popover
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开仪表板", action: #selector(openDashboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "充电至 100%", action: #selector(topUp), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 AIBattery", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openDashboard() { showWindow() }
    @objc private func topUp() { state.topUp() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func observeState() {
        state.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        state.$chargeVal.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &cancellables)
        state.$showPercentage.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &cancellables)
        state.$menuBarIconStyle.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &cancellables)
        state.$selectedMenuBarItems.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &cancellables)
        state.$colorMode.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.window?.appearance = NSAppearance(named: self?.state.colorMode == 1 ? .aqua : .darkAqua)
            self?.updateStatusItem()
        }.store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        if state.menuBarIconStyle == 0 {
            statusItem?.length = 0
            button.image = nil
            button.title = ""
            return
        }
        statusItem?.length = NSStatusItem.variableLength
        let symbol = state.menuBarIconStyle == 3 ? "battery.100" : "battery.100.bolt"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AIBattery")
        image?.isTemplate = true
        button.image = image

        var parts: [String] = []
        if state.showPercentage { parts.append("\(state.snapshot.percentage)%") }
        if state.selectedMenuBarItems.contains(MenuBarItem.temperature.rawValue) {
            parts.append(String(format: "%.0f°C", state.snapshot.temperature))
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.cycleCount.rawValue) {
            parts.append("\(state.snapshot.cycleCount)")
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.maxCapacity.rawValue) {
            parts.append("\(state.snapshot.healthPercent)%")
        }
        if state.selectedMenuBarItems.contains(MenuBarItem.voltage.rawValue) {
            parts.append(String(format: "%.1fV", state.snapshot.voltage))
        }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.imagePosition = .imageLeading
    }
}
