//
//  SleepControl.swift
//  Power assertions, lid state and screen locking.
//
//  These are the three things the 「睡眠与能源」 panel promises. Each one maps to
//  a real system API, so the switches either do something or the UI says why not.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

final class SleepControl {

    static let shared = SleepControl()

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    private init() {}

    /// Holds the machine awake while `disableSleep` is on. `allowDisplaySleep`
    /// mirrors the 「禁用睡眠时关闭显示器」 switch: when it is on, only the
    /// system assertion is taken and the screen may still turn off.
    func apply(disableSleep: Bool, allowDisplaySleep: Bool) {
        guard disableSleep else {
            release(&systemAssertion)
            release(&displayAssertion)
            return
        }
        create(&systemAssertion,
               kIOPMAssertionTypePreventUserIdleSystemSleep,
               "InfiniCal: keep system awake")
        if allowDisplaySleep {
            release(&displayAssertion)
        } else {
            create(&displayAssertion,
                   kIOPMAssertionTypePreventUserIdleDisplaySleep,
                   "InfiniCal: keep display awake")
        }
    }

    private func create(_ id: inout IOPMAssertionID, _ type: String, _ name: String) {
        guard id == 0 else { return }
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString,
                                                 &created)
        if result == kIOReturnSuccess { id = created }
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    /// Lid state from the power-management root domain. Absent on desktops,
    /// which read as "open".
    func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service,
                                                          "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault,
                                                          0)?.takeRetainedValue() else { return false }
        return (value as? Bool) ?? false
    }

    /// Locks the screen through login.framework. Returns false when the entry
    /// point is missing, so the caller can report it instead of doing nothing.
    @discardableResult
    func lockScreen() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) else {
            return false
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
        return true
    }
}
