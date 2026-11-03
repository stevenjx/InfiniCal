//
//  PowerMeter.swift
//  Live total power for the flow diagram.
//
//  Why this exists
//  ---------------
//  `PowerTelemetryData.SystemLoad` / `SystemPowerIn` look like live sensors but
//  they are **one-minute snapshots**: `UpdateTime` only advances every 60 s and
//  `SystemLoadAccumulatorCount` only grows in the same 60 s step (measured:
//  +56 counts per 60 s, 0 counts in any 10 s window). Showing them raw means the
//  UI can be up to a minute behind the machine — which is why the numbers used
//  to disagree with other apps by 2x whenever the load changed.
//
//  The SMC keys `PSTR` / `PDTR` carry the same physical quantity but refresh at
//  roughly 5 Hz. Measured on Mac14,9:
//      idle    PSTR 16.82 W   SystemLoad 15.35 W
//      loaded  PSTR 30.46 W   SystemLoad 29.80 W   (8 × `yes`)
//      after   PSTR 14.28 W   SystemLoad 29.80 W   ← snapshot had not caught up
//      steady  PSTR 14.72 W   SystemLoad 14.72 W   ← exact agreement
//
//  `PDTR` is the previous `PSTR` sample (PSTR(t+1) == PDTR(t)), so the pair gives
//  a 0.2 s resolution signal. We use PSTR, fall back to PDTR, and only fall back
//  to the 60 s snapshot when neither key exists (e.g. Intel Macs).
//

import Foundation

final class PowerMeter {

    struct Reading {
        /// Total power currently drawn by the machine, in watts.
        var total: Double = 0
        /// One-minute average reported by the battery driver, in watts.
        var average: Double = 0
        /// Which source produced `total`.
        var source: String = "—"
        var isLive: Bool = false
    }

    private var cachedKeys: (pstr: SMCKeyInfo, pdtr: SMCKeyInfo)?
    private var keysProbed = false
    private var lastGood: Double = 0
    /// Measured on Mac14,9: the first few reads after launch return inflated
    /// values (17.9 → 28.2 → 14.2 W on an idle machine, where the 60 s snapshot
    /// said 7.1 W), and steady state oscillates ±50 % between two consecutive
    /// ticks. Both are handled here: a short warm-up plus a 5-sample median.
    private var warmup = 0
    private var recent: [Double] = []

    /// Reads the SMC power pair. Cheap enough to call a few times per second.
    func sample(fallback: BatterySnapshot) -> Reading {
        var reading = Reading()
        reading.average = fallback.systemLoad

        if !keysProbed {
            keysProbed = true
            if let a = SMC.shared.keyInfo("PSTR"), let b = SMC.shared.keyInfo("PDTR") {
                cachedKeys = (a, b)
            }
        }

        if cachedKeys != nil {
            var values: [Double] = []
            if let v = try? SMC.shared.readDouble("PSTR"), v > 0.01, v < 200 {
                values.append(v)
            }
            if let v = try? SMC.shared.readDouble("PDTR"), v > 0.01, v < 200 {
                values.append(v)
            }
            if let latest = values.first {
                warmup += 1
                // PSTR is only rewritten once per ~4 s, so within the first second
                // we may see the same value repeatedly and a "median" of identical
                // samples is just that value. Nothing to compensate for: the value
                // is the newest firmware sample, the display ramps via the view's
                // own smoothing.
                // Median of the PSTR samples seen so far. The raw key alternates
                // between e.g. 8.2 / 12.3 / 9.3 within one second, so a mean would
                // still wobble while the median follows the real level and ignores
                // the spikes. During warm-up the first inflated reads are simply
                // outvoted as more samples arrive.
                recent.append(latest)
                if recent.count > 5 { recent.removeFirst() }
                let sorted = recent.sorted()
                let median = sorted[sorted.count / 2]
                lastGood = median
                reading.total = median
                // After 8 samples (~4 s) the median is trustworthy; before that it
                // is still settling, so the residual "其他" is suppressed.
                reading.source = "SMC PSTR"
                reading.isLive = warmup >= 8
                return reading
            }
        }

        // Intel / older SMC: no PSTR. The 60 s snapshot is all we have.
        if fallback.systemLoad > 0.01 {
            reading.total = fallback.systemLoad
            reading.source = t("SystemLoad（60 秒快照）")
            reading.isLive = false
            return reading
        }

        reading.total = lastGood
        reading.source = t("SMC PSTR（缓存）")
        reading.isLive = false
        return reading
    }
}
