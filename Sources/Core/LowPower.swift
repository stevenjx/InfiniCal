//
//  LowPower.swift
//  "Will this machine make it to a charger?" — the one alert that is about the
//  user rather than the hardware.
//
//  Everything here is a pure function over values so the thresholds can be
//  asserted without a battery. The sampling window exists because a single
//  sample is not a rate: opening a window can double the draw for ten seconds
//  and that must not turn into "2 minutes left".
//

import Foundation

/// Rolling average of the discharge rate, so the estimate behind an alert is
/// not chasing one tick.
struct DischargeWatch {

    /// Seconds of history the average covers.
    static let window: TimeInterval = 180
    /// Above this the samples are too old to describe "now".
    static let staleAfter: TimeInterval = 300

    private var samples: [(date: Date, watts: Double)] = []

    /// Positive watts leave the pack. Negative or non-finite values are the
    /// charger's, not the load's, and are dropped rather than clamped to zero —
    /// a charging hour must not average into a discharge estimate.
    mutating func record(watts: Double, at date: Date) {
        guard watts.isFinite, watts > 0 else { return }
        samples.append((date, watts))
        let cutoff = date.addingTimeInterval(-Self.window)
        if let first = samples.firstIndex(where: { $0.date >= cutoff }) {
            if first > 0 { samples.removeFirst(first) }
        } else {
            samples.removeAll()
        }
    }

    mutating func reset() { samples.removeAll() }

    /// Mean over the window, or nil when there is nothing recent to average.
    func average(at now: Date) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.date) <= Self.staleAfter }
        guard !recent.isEmpty else { return nil }
        let sum = recent.reduce(0) { $0 + $1.watts }
        let mean = sum / Double(recent.count)
        return mean > 0.05 ? mean : nil
    }

    var sampleCount: Int { samples.count }
}

enum LowPowerPolicy {

    /// Below this the alert is a fact ("5 % left"), not a prediction.
    static let criticalPercentage = 5
    /// Refuse to publish an estimate from a draw this small: the remaining time
    /// would be measured in days and the number would be fiction.
    static let minimumWatts = 0.5
    static let defaultLeadMinutes = 20
    static let leadOptions = [10, 20, 30, 45, 60]

    /// Minutes of runtime left at a given average draw.
    ///
    /// Same arithmetic as the dashboard's 剩余 estimate — pack energy over
    /// power — so the two numbers cannot disagree about what they measure.
    static func minutesLeft(remainingMAh: Int, voltage: Double, watts: Double) -> Int? {
        guard remainingMAh > 0, voltage > 5, voltage < 20, watts >= minimumWatts else { return nil }
        let wattHours = Double(remainingMAh) / 1000 * voltage
        let hours = wattHours / watts
        guard hours.isFinite, hours >= 0 else { return nil }
        return min(7 * 24 * 60, Int((hours * 60).rounded()))
    }
    /// An estimate below the lead time is worth a banner. A missing estimate is
    /// not: no number means no claim.
    ///
    /// The critical floor is deliberately independent of the estimate: at 3 %
    /// the pack is nearly empty whatever the average says, and the estimate can
    /// still be above the lead time when the load is light.
    ///
    /// Turning the alert off is not this function's job — the rule lives in
    /// `AnomalyAlerts` and is disabled there like every other one, so the
    /// settings switch and 「关闭此类」 cannot drift apart.
    static func shouldWarn(minutesLeft: Int?, lead: Int, percentage: Int) -> Bool {
        if isCritical(percentage) { return true }
        guard let minutes = minutesLeft else { return false }
        return minutes <= lead
    }

    static func isCritical(_ percentage: Int) -> Bool {
        percentage > 0 && percentage <= criticalPercentage
    }

    /// How far above the lead time the estimate has to climb before the alert
    /// clears.
    ///
    /// Without a margin the rule would re-arm and re-fire around the threshold:
    /// a 3-minute average wanders by a few minutes whenever a process wakes up.
    /// It scales with the lead time so a 60-minute warning does not flicker
    /// either.
    static func recoveryMinutes(lead: Int) -> Int {
        lead + max(5, lead / 5)
    }

    /// Whether the alert may be cleared again.
    ///
    /// Plugging in is the obvious case. The other is "the estimate climbed well
    /// past the threshold" — but only *above* the critical floor: at 3 % the
    /// pack is nearly empty whatever the average says, and clearing there would
    /// let the rule fire again a minute later.
    ///
    /// A missing estimate counts as recovered: no measurable draw means the
    /// machine is idle or asleep, not that it is about to die.
    static func shouldRecover(percentage: Int, minutesLeft: Int?,
                              lead: Int, pluggedIn: Bool) -> Bool {
        if pluggedIn { return true }
        guard percentage > criticalPercentage else { return false }
        guard let minutes = minutesLeft else { return true }
        return minutes > recoveryMinutes(lead: lead)
    }

    /// The evidence line behind a 低电量 banner.
    ///
    /// It has to say how the number was produced, and it has to stay honest when
    /// there is no number at all: the 5 % floor fires without an estimate, and
    /// quoting a runtime there would be an invention.
    static func evidence(percentage: Int, leadMinutes: Int,
                         averageWatts: Double?, minutesLeft: Int?,
                         windowSeconds: Int) -> String {
        let head = "SOC=\(percentage)%; lead=\(leadMinutes) min"
        guard let minutes = minutesLeft, let watts = averageWatts, watts > 0 else {
            return head + "; 剩余时间无法估算（放电电流过小），仅按电量判断"
        }
        return head + String(format: "; %.1f W / %d s → 剩余 %d min",
                             watts, windowSeconds, minutes)
    }
}