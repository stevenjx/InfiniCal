//
//  SystemChargeLimit.swift
//  macOS 26+：系统自带的充电上限（PowerUI 的 Manual Charge Limit）。
//
//  为什么需要它：从 macOS 26 起，新款 Mac 的 SMC 不再暴露 BCLM / CH0B / CH0C /
//  CHTE（在 Mac14,9 + macOS 27 上实测：这些键全部返回 keyNotFound，只剩 CHIE
//  一个适配器开关）。这意味着「充电限制」在这类机器上根本无处可写，App 原本会
//  直接抛 "此机型未暴露充电限制键"。
//
//  系统自己在同一时期提供了 MCL：它就是「系统设置 → 电池 → 充电上限」那张滑块
//  背后的机制，由 powerd 持有，写进去会被系统持久执行（不需要 400 ms 脉冲去跟
//  macOS 抢同一个键）。AlDente Pro 在 macOS 26+ 上走的也是这条路径
//  （其二进制中的 "apply discharge: writing MCL limit" 即此）。
//
//  约束（实测）：
//    • 只接受 80…100，写 79 会返回 PowerUISmartChargingErrorDomain Code=4
//    • 上限低于当前电量时，系统会把电放到该上限——这正是「放电至充电上限」
//    • 首次写入前需要 enableMCL，否则 setMCLLimit 返回成功但值不变
//
//  私有框架，但只通过运行时查找调用：找不到就整体降级为「不可用」，不链接、
//  不影响 macOS 12 的构建与运行。
//

import Foundation

final class SystemChargeLimit {

    static let shared = SystemChargeLimit()

    /// 系统 MCL 的支持区间。低于下限的目标只能交给 SMC 适配器开关去做。
    static let minimumSupported = 80
    static let maximumSupported = 100

    private typealias EnableFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>?) -> Bool
    private typealias SetLimitFn = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<AnyObject?>?) -> Bool
    private typealias GetLimitFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>?) -> UInt8
    private typealias GetEnabledFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>?) -> UInt64
    private typealias PlainBoolFn = @convention(c) (AnyObject, Selector) -> Bool

    private var client: AnyObject?
    private var clientClass: AnyClass?
    private var available: Bool?
    private let lock = NSLock()

    private init() {}

    // MARK: - 探测

    /// 一次性加载 PowerUI 并确认 MCL 可用。任何一步失败都返回 false，
    /// 调用方据此回退到 SMC。
    private func probe() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let available { return available }
        available = false
        client = makeClient()
        available = client != nil
        return available!
    }

    private func makeClient() -> AnyObject? {
        // macOS 26 之前没有这个 API。
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else { return nil }

        let path = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
        guard dlopen(path, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") else { return nil }

        let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        guard let instance = allocated?
            .perform(NSSelectorFromString("initWithClientName:"), with: "InfiniCal" as NSString)?
            .takeUnretainedValue() else { return nil }

        // Selectors are looked up on the class found by name, not via
        // `object_getClass(instance)`: an `AnyObject` handed back through
        // `perform` can be bridged, and the bridged object's class is not the
        // PowerUI class — every lookup then returned nil, intermittently.
        clientClass = cls
        enableFn = function("enableMCL:", as: EnableFn.self)
        setLimitFn = function("setMCLLimit:error:", as: SetLimitFn.self)
        getLimitFn = function("getMCLLimitWithError:", as: GetLimitFn.self)
        getEnabledFn = function("isMCLCurrentlyEnabled:", as: GetEnabledFn.self)

        // A client alone is not enough: without MCL support every write is
        // refused, so the whole backend must report as unavailable instead.
        guard let supported = function("isMCLSupported", as: PlainBoolFn.self),
              supported(instance, NSSelectorFromString("isMCLSupported")) else {
            forgetFunctions()
            return nil
        }
        return instance
    }

    private var enableFn: EnableFn?
    private var setLimitFn: SetLimitFn?
    private var getLimitFn: GetLimitFn?
    private var getEnabledFn: GetEnabledFn?

    private func forgetFunctions() {
        enableFn = nil; setLimitFn = nil; getLimitFn = nil; getEnabledFn = nil
        clientClass = nil
    }

    private func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let clientClass,
              let method = class_getInstanceMethod(clientClass, NSSelectorFromString(name)) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }

    // MARK: - 查询

    var isAvailable: Bool { probe() }

    /// 系统当前生效的上限（%）。不可用或读失败时为 nil。
    var limit: Int? {
        guard probe(), let client, let read = getLimitFn else { return nil }
        var error: AnyObject?
        let value = read(client, NSSelectorFromString("getMCLLimitWithError:"), &error)
        guard error == nil else { return nil }
        return Int(value)
    }

    /// 上限是否处于启用状态。
    var isEnabled: Bool {
        guard probe(), let client, let read = getEnabledFn else { return false }
        var error: AnyObject?
        let value = read(client, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error)
        return error == nil && value != 0
    }

    /// 系统是否正把电量维持在一个低于满电的上限上。用于判断「系统自己在限制充电」。
    var holdsBelowFull: Bool {
        guard let value = limit else { return false }
        return value < 99
    }

    // MARK: - 写入

    /// What `setLimit` would actually write for `percent`.
    func clamped(_ percent: Int) -> Int {
        max(SystemChargeLimit.minimumSupported, min(SystemChargeLimit.maximumSupported, percent))
    }

    /// 设置上限。区间外的值会被夹到 80…100；返回是否确认生效。
    ///
    /// 写后读回校验：`setMCLLimit` 在 MCL 未启用时会返回成功却什么也不做，
    /// 所以「返回 true」不能当作生效的依据。
    @discardableResult
    func setLimit(_ percent: Int) -> Bool {
        // `probe()` must run before `client` is read: it is what creates it.
        guard probe(), let client, let write = setLimitFn, let read = getLimitFn else { return false }
        let target = clamped(percent)

        if !isEnabled {
            guard let enable = enableFn else { return false }
            var error: AnyObject?
            _ = enable(client, NSSelectorFromString("enableMCL:"), &error)
            guard error == nil else { return false }
        }

        var error: AnyObject?
        let ok = write(client, NSSelectorFromString("setMCLLimit:error:"), UInt8(target), &error)
        guard ok, error == nil else { return false }

        var readError: AnyObject?
        let applied = read(client, NSSelectorFromString("getMCLLimitWithError:"), &readError)
        return readError == nil && Int(applied) == target
    }
}
