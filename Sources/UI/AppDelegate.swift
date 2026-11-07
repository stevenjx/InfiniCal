//
//  AppDelegate.swift
//  Main application window.
//

import AppKit
import SwiftUI

struct ThemedRoot: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        RootView()
            .preferredColorScheme(state.theme.isDark ? .dark : .light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var menuBar: MenuBarController?
    private let state = AppState.shared

    /// Registered before the first window exists: a cold start from
    /// `open infinical://limit/60` delivers the Apple Event between
    /// `willFinishLaunching` and `didFinishLaunching`, so the handler has to be
    /// in place by then. The event is queued by `AutomationCenter` until the
    /// timers are up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        // The other arrival path: a second copy launched by LaunchServices
        // forwards the URL it was given instead of dropping it on exit.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleForwardedURL(_:)),
            name: Notification.Name(AutomationURL.notificationName),
            object: nil)
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        AutomationCenter.shared.handle(url)
    }

    @objc private func handleForwardedURL(_ note: Notification) {
        guard let string = note.object as? String, let url = URL(string: string) else { return }
        AutomationCenter.shared.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--panel"), index + 1 < CommandLine.arguments.count,
           let panel = Panel(rawValue: CommandLine.arguments[index + 1]) {
            state.selectedPanel = panel
        }
        // The app may run as an accessory (no Dock icon) or a regular app; the
        // status item is always present, so closing the window is never a dead end.
        Task { @MainActor in SparkleUpdater.shared.checkInBackground() }
        state.applyDockPreference()
        state.reconcileLaunchAtLogin()
        menuBar = MenuBarController { [weak self] in self?.openMainWindow() }
        showWindow()
        if CommandLine.arguments.contains("--menubar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.menuBar?.showPopover()
            }
        }
        observeThemeChanges()
        // Anything that arrived during the cold start can run now.
        AutomationCenter.shared.markReady()
    }

    /// Reopen path: the window is closable but the process keeps running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func openMainWindow() {
        menuBar?.closePopover()
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CalibrationEngine.shared.prepareForTermination()
        FanController.shared.restoreSystemControl()
        state.closeChargeSession()
        state.saveHistory()
        DailyHistory.shared.save()
        if state.exitInhibitCharge {
            try? ChargeController.shared.setChargingAllowed(true)
        }
    }

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: ThemedRoot().environmentObject(state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered,
                                  defer: false)
            window.title = "InfiniCal"
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
        NSApp.activateInFront()
    }

    private func observeThemeChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.state.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.window?.appearance = NSAppearance(named: self.state.colorMode == 1 ? .aqua : .darkAqua)
            }
    }
}

// MARK: - Activation

extension NSApplication {
    /// macOS 14 deprecates `activate(ignoringOtherApps:)` and only there adds the
    /// replacement, so the 12/13 range keeps the old call.
    func activateInFront() {
        if #available(macOS 14.0, *) { activate() } else { activate(ignoringOtherApps: true) }
    }
}

extension NSRunningApplication {
    func activateInFront() {
        if #available(macOS 14.0, *) { activate() } else { activate(options: [.activateIgnoringOtherApps]) }
    }
}
