//
//  main.swift
//

import AppKit

let application = NSApplication.shared

// Launch-at-login bootstraps a LaunchAgent with RunAtLoad, which starts the app
// immediately. Without this guard, turning the setting on (or logging in while a
// copy is already running) leaves two menu bar icons for the same app.
let identifier = Bundle.main.bundleIdentifier ?? "com.infinitycomputer.infinical"
if let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    .first(where: { $0.processIdentifier != getpid() }) {
    // `open infinical://pause` sometimes lands here instead of reusing the
    // running copy: LaunchServices started us for the URL. The URL is in argv,
    // so hand it to the instance that will survive before exiting — otherwise
    // the command disappears with this process.
    if let url = CommandLine.arguments.first(where: { $0.lowercased().hasPrefix("infinical://") }),
       let parsed = URL(string: url) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(AutomationURL.notificationName),
            object: parsed.absoluteString,
            userInfo: nil,
            deliverImmediately: true)
        // Distributed notifications are asynchronous across processes; the
        // poster has to stay alive long enough for the delivery to happen.
        Thread.sleep(forTimeInterval: 0.25)
    }
    other.activateInFront()
    exit(0)
}

let delegate = AppDelegate()
application.delegate = delegate
// Dock presence is a setting; read it before `run()` so the icon does not
// flicker in after launch. AppDelegate re-applies it once the defaults load.
let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
application.setActivationPolicy(showInDock ? .regular : .accessory)
application.run()
