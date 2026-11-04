// Activate a running InfiniCal instance and print its main window id.
//
// `open -a` refuses to pass `--args` on this machine and `osascript activate`
// starts a *second* instance without the arguments, which is why the panel
// argument used to look broken. Launching the binary directly keeps argv, and
// this tool brings that instance forward without spawning anything, so
// `screencapture -l <id>` can grab a deterministic window image.
//
// Usage: window_tool <pid> [--wait milliseconds]

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write("usage: window_tool <pid>\n".data(using: .utf8)!)
    exit(64)
}

var waitMilliseconds = 400
if let flag = args.firstIndex(of: "--wait"), flag + 1 < args.count,
   let value = Int(args[flag + 1]) {
    waitMilliseconds = value
}

if let app = NSRunningApplication(processIdentifier: pid) {
    _ = app.activate(options: [.activateAllWindows])
}
usleep(useconds_t(max(0, waitMilliseconds)) * 1000)

func windows(onScreenOnly: Bool) -> [[String: Any]] {
    let options: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll]
    return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}

/// The app owns several layer-0 windows (popover, sheets); the main window is
/// the widest one. Picking by size avoids depending on window titles, which
/// are hidden here.
func widest(_ list: [[String: Any]]) -> Int? {
    let owned = list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    let sorted = owned.sorted { left, right in
        let a = (left[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
        let b = (right[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
        return a > b
    }
    return sorted.first.flatMap { $0[kCGWindowNumber as String] as? Int }
}

if let id = widest(windows(onScreenOnly: true)) ?? widest(windows(onScreenOnly: false)) {
    print(id)
} else {
    FileHandle.standardError.write("no window for pid \(pid)\n".data(using: .utf8)!)
    exit(2)
}
