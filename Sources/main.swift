//
//  main.swift
//

import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Dock presence is a setting; read it before `run()` so the icon does not
// flicker in after launch. AppDelegate re-applies it once the defaults load.
let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
application.setActivationPolicy(showInDock ? .regular : .accessory)
application.run()
