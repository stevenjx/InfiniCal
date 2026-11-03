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
            let held = systemAssertion != 0 || displayAssertion != 0
            release(&systemAssertion)
            release(&displayAssertion)
            // Only worth a line when something was actually let go; otherwise
            // every settings change would append a no-op.
            if held {
                ControlJournal.shared.record(ControlEvidence(
                    operation: "sleep.assertion", backend: "iokit", phase: .restored,
                    target: "off", observed: "assertions released"))
            }
            return
        }
        let systemOK = create(&systemAssertion,
                              kIOPMAssertionTypePreventUserIdleSystemSleep,
                              "InfiniCal: keep system awake")
        ControlJournal.shared.record(ControlEvidence(
            operation: "sleep.system", backend: "iokit",
            phase: systemOK ? .verified : .failed,
            target: "prevent idle sleep",
            observed: systemOK ? "assertion \(systemAssertion)" : nil,
            detail: systemOK ? nil : t("系统拒绝了防睡眠断言")))
        if allowDisplaySleep {
            let wasHeld = displayAssertion != 0
            release(&displayAssertion)
            if wasHeld {
                ControlJournal.shared.record(ControlEvidence(
                    operation: "sleep.display", backend: "iokit", phase: .restored,
                    target: "allow display sleep", observed: "assertion released"))
            }
        } else {
            let displayOK = create(&displayAssertion,
                                   kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                   "InfiniCal: keep display awake")
            ControlJournal.shared.record(ControlEvidence(
                operation: "sleep.display", backend: "iokit",
                phase: displayOK ? .verified : .failed,
                target: "prevent display sleep",
                observed: displayOK ? "assertion \(displayAssertion)" : nil,
                detail: displayOK ? nil : t("系统拒绝了防息屏断言")))
        }
    }

    @discardableResult
    private func create(_ id: inout IOPMAssertionID, _ type: String, _ name: String) -> Bool {
        // Already held: the caller's intent is satisfied, so report success
        // instead of silently recording a duplicate.
        guard id == 0 else { return true }
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString,
                                                 &created)
        guard result == kIOReturnSuccess else { return false }
        id = created
        return true
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
            ControlJournal.shared.record(ControlEvidence(
                operation: "sleep.lock", backend: "login.framework", phase: .failed,
                target: "lock screen", detail: t("当前系统未提供锁屏接口")))
            return false
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            ControlJournal.shared.record(ControlEvidence(
                operation: "sleep.lock", backend: "login.framework", phase: .failed,
                target: "lock screen", detail: t("当前系统未提供锁屏接口")))
            return false
        }
        typealias LockFunction = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
        // The call returns without a status; the request was delivered, which is
        // as much as this API can tell us.
        ControlJournal.shared.record(ControlEvidence(
            operation: "sleep.lock", backend: "login.framework", phase: .accepted,
            target: "lock screen", detail: t("锁屏调用已交给系统，无法回读结果")))
        return true
    }
}
