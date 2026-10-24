//
//  PowerEstimate.swift
//  Fallback power sources for components this platform cannot measure.
//
//  Everything here is explicitly labelled: a reading carries its quality
//  (measured / estimated / unavailable) so the UI never presents a model output
//  as if it came from a sensor.
//

import Foundation
import Darwin
import CoreGraphics

enum PowerQuality {
    case measured
    case estimated
    case unavailable

    var badge: String {
        switch self {
        case .measured: return t("实测")
        case .estimated: return t("估算")
        case .unavailable: return t("不可用")
        }
    }
}

struct PowerReading {
    var watts: Double?
    var quality: PowerQuality
    var note: String?

    static let unavailable = PowerReading(watts: nil, quality: .unavailable, note: nil)

    static func measured(_ watts: Double) -> PowerReading {
        PowerReading(watts: watts, quality: .measured, note: nil)
    }

    static func estimated(_ watts: Double, note: String) -> PowerReading {
        PowerReading(watts: max(0, watts), quality: .estimated, note: note)
    }
}

// MARK: - CPU utilisation

/// Instantaneous CPU utilisation from the host's tick counters.
final class CPULoadSampler {

    private var previous: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func read() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        defer { previous = (user, system, idle, nice) }

        guard let last = previous else { return 0 }
        let userDelta = Double(user &- last.user)
        let systemDelta = Double(system &- last.system)
        let idleDelta = Double(idle &- last.idle)
        let niceDelta = Double(nice &- last.nice)
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return 0 }
        return min(1, max(0, (userDelta + systemDelta + niceDelta) / total))
    }
}

// MARK: - Display brightness

/// Private DisplayServices API — the same framework AlDente links for its
/// display power estimate. Returns the backlight level in 0…1.
final class BrightnessReader {

    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private var function: GetBrightnessFn?
    private var handle: UnsafeMutableRawPointer?

    init() {
        let candidates = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices"
        ]
        for path in candidates {
            guard let h = dlopen(path, RTLD_NOW) else { continue }
            guard let symbol = dlsym(h, "DisplayServicesGetBrightness") else {
                dlclose(h)
                continue
            }
            handle = h
            function = unsafeBitCast(symbol, to: GetBrightnessFn.self)
            break
        }
    }

    deinit { if let handle { dlclose(handle) } }

    func brightness() -> Double? {
        guard let function else { return nil }
        var value: Float = 0
        let result = function(CGMainDisplayID(), &value)
        guard result == 0, value >= 0, value <= 1.001 else { return nil }
        return Double(min(1, max(0, value)))
    }
}

// MARK: - Estimator

/// Transparent models used only when no measured source exists.
/// Both formulas are shown verbatim in the UI tooltip so the number is never
/// mistaken for a sensor reading.
final class PowerEstimator {

    static let socFormula = t("SoC ≈ 1.2 W + 22.0 × CPU占用^1.25")
    static let displayFormula = t("显示 ≈ 0.6 W + 4.4 × 亮度^1.6（14 英寸 mini-LED 典型值）")

    let cpu = CPULoadSampler()
    let brightness = BrightnessReader()

    /// Utilisation is sampled instantaneously, which swings several watts between
    /// two samples. A silicon die has thermal mass, so its power draw is far
    /// steadier than a raw tick delta — an 8 s exponential mean is both more
    /// realistic and much calmer on screen.
    private var loadFilter = ExponentialFilter(tau: 8)
    private var brightnessFilter = ExponentialFilter(tau: 6)

    func estimateSoC() -> PowerReading {
        let load = loadFilter.push(cpu.read())
        let watts = 1.2 + 22.0 * pow(load, 1.25)
        return .estimated(watts, note: Self.socFormula + String(format: t("，8 秒均值 CPU %.0f%%"), load * 100))
    }

    func estimateDisplay() -> PowerReading {
        guard let level = brightness.brightness() else { return .unavailable }
        let stable = brightnessFilter.push(level)
        let watts = 0.6 + 4.4 * pow(stable, 1.6)
        return .estimated(watts, note: Self.displayFormula + String(format: t("，当前亮度 %.0f%%"), stable * 100))
    }
}

// MARK: - Smoothing

/// Time-constant based exponential mean. Used by the estimators so a value that
/// is sampled every couple of seconds still changes at a human pace.
struct ExponentialFilter {
    var tau: Double
    private var value: Double?
    private var last = Date()

    init(tau: Double) { self.tau = tau }

    mutating func push(_ sample: Double) -> Double {
        let now = Date()
        let dt = min(10, max(0.1, now.timeIntervalSince(last)))
        last = now
        guard let previous = value else {
            value = sample
            return sample
        }
        let k = 1 - exp(-dt / max(0.1, tau))
        let next = previous + (sample - previous) * k
        value = next
        return next
    }
}
