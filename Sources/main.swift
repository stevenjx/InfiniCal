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
    other.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}

let delegate = AppDelegate()
application.delegate = delegate
// Dock presence is a setting; read it before `run()` so the icon does not
// flicker in after launch. AppDelegate re-applies it once the defaults load.
let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
application.setActivationPolicy(showInDock ? .regular : .accessory)
application.run()
