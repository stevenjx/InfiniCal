//
//  PowerSampler.swift
//  SoC / display power from IOReport's "Energy Model" counters.
//
//  Findings on this machine (Mac14,9, macOS 27), verified with a standalone
//  probe (tools/powersnap.c):
//    • /usr/lib/libIOReport.dylib loads and the "Energy Model" group exposes
//      177 channels, including "CPU Energy", "GPU Energy", "ANE0", "DRAM0".
//    • The cumulative counters never advance — even under sustained 100 % CPU
//      load for 12 s the delta is exactly 0 mJ, while "GPU Energy" returns a
//      meaningless 10^14-scale number.
//    • IOReportCreateSamplesDelta() returns 0 for every energy channel, and
//      taking a second sample in the same process crashes inside the framework.
//
//  A broken counter must never turn into a made-up watt value, so the app
//  reports "unavailable" for these two components and folds them into "其他".
//  The sampler stays behind this small API so a future OS (or a privileged
//  probe) can plug real numbers back in without touching the UI.
//

import Foundation

final class PowerSampler {

    struct Reading {
        var soc: Double?
        var display: Double?
    }

    /// Human readable state, surfaced in the settings diagnostics.
    private(set) var status: String = "IOReport 能量计数器不可用"

    /// Per-component power when the platform exposes it. Currently always nil
    /// because the counters do not advance on this macOS build.
    func read() -> Reading {
        Reading(soc: nil, display: nil)
    }
}
