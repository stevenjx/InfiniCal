//
//  CalibrationMath.swift
//  The measurement maths behind a calibration run.
//
//    • CoulombIntegrator — trapezoidal integration of current × time, the only
//      honest way to know how much charge actually moved through the pack.
//    • DCIRCalculator    — internal resistance from current steps and the
//      voltage response that follows them.
//    • BatteryHealthModel — Kalman smoothing for live power, a fused estimate of
//      true capacity, and the runtime projection.
//
//  All three are pure state machines: feed them samples, read numbers back.
//

import Foundation

// MARK: - Coulomb counting

struct CoulombTotals {
    var dischargeAh: Double = 0
    var dischargeWh: Double = 0
    var rechargeAh: Double = 0
    var rechargeWh: Double = 0

    mutating func reset() {
        dischargeAh = 0
        dischargeWh = 0
        rechargeAh = 0
        rechargeWh = 0
    }
}

/// Trapezoidal integrator. Sign of the current decides which bucket a slice of
/// charge goes into, so one instance tracks both halves of a full cycle.
final class CoulombIntegrator {

    private(set) var totals = CoulombTotals()

    private var lastUptime: TimeInterval?
    private var lastCurrent: Double = 0
    private var lastPower: Double = 0

    /// Currents below this are fuel-gauge noise around zero, not real flow.
    private let deadband: Double

    init(deadband: Double = 0.025) {
        self.deadband = deadband
    }

    func reset() {
        totals.reset()
        lastUptime = nil
        lastCurrent = 0
        lastPower = 0
    }

    /// Zeroes one bucket without touching the other, and without breaking the
    /// trapezoid: `lastCurrent` / `lastPower` stay, so the next slice is still
    /// integrated from the previous sample.
    ///
    /// Phase transitions need this. Charge moved while topping up to 100 % is
    /// neither part of the discharge span nor part of the recharge that follows
    /// it, and leaving it in the recharge bucket understates coulombic
    /// efficiency by however long the pre-charge took.
    func resetDischargeBucket() {
        totals.dischargeAh = 0
        totals.dischargeWh = 0
    }

    func resetRechargeBucket() {
        totals.rechargeAh = 0
        totals.rechargeWh = 0
    }

    func step(uptime: TimeInterval, currentSignedAmps: Double, voltageVolts: Double) -> CoulombTotals {
        let current = abs(currentSignedAmps) <= deadband ? 0 : currentSignedAmps
        let power = voltageVolts * current

        guard let previous = lastUptime else {
            lastUptime = uptime
            lastCurrent = current
            lastPower = power
            return totals
        }

        let deltaSeconds = uptime - previous
        // A gap longer than 5 s means the process was suspended; integrating
        // across it would invent charge that never moved.
        if deltaSeconds <= 0 || deltaSeconds > 5 {
            lastUptime = uptime
            lastCurrent = current
            lastPower = power
            return totals
        }

        let deltaHours = deltaSeconds / 3600
        let averageCurrent = (lastCurrent + current) / 2
        let averagePower = (lastPower + power) / 2

        if averageCurrent < 0 {
            totals.dischargeAh += abs(averageCurrent) * deltaHours
            totals.dischargeWh += abs(averagePower) * deltaHours
        } else if averageCurrent > 0 {
            totals.rechargeAh += averageCurrent * deltaHours
            totals.rechargeWh += averagePower * deltaHours
        }

        lastUptime = uptime
        lastCurrent = current
        lastPower = power
        return totals
    }
}

// MARK: - Internal resistance

/// Estimates DC internal resistance from the voltage step that follows a load
/// step. Requires the two to move in opposite directions, which is what a real
/// cell does and what noise does not.
final class DCIRCalculator {

    private struct Sample {
        let uptime: TimeInterval
        let current: Double
        let voltage: Double
    }

    private var window: [Sample] = []
    private var recent: [Double] = []
    private var filtered: Double?

    private let minimumStepAmps: Double
    private let maximumWindowSeconds: TimeInterval
    private let smoothing: Double

    init(minimumStepAmps: Double = 1.0, maximumWindowSeconds: TimeInterval = 2.0, smoothing: Double = 0.20) {
        self.minimumStepAmps = minimumStepAmps
        self.maximumWindowSeconds = maximumWindowSeconds
        self.smoothing = smoothing
    }

    func reset() {
        window.removeAll()
        recent.removeAll()
        filtered = nil
    }

    func feed(uptime: TimeInterval, currentAmps: Double, voltageVolts: Double) -> Double? {
        let sample = Sample(uptime: uptime, current: currentAmps, voltage: voltageVolts)
        window.append(sample)
        window.removeAll { uptime - $0.uptime > maximumWindowSeconds }

        guard let oldest = window.first else { return filtered }

        let deltaI = sample.current - oldest.current
        let deltaV = sample.voltage - oldest.voltage
        let deltaT = sample.uptime - oldest.uptime

        guard abs(deltaI) >= minimumStepAmps, deltaT >= 0.8, deltaI * deltaV < 0 else { return filtered }

        let milliOhms = abs(deltaV) / abs(deltaI) * 1000
        // Polymer cells live in this range; anything outside is a mis-paired step.
        guard milliOhms >= 10, milliOhms <= 600 else { return filtered }

        recent.append(milliOhms)
        if recent.count > 5 { recent.removeFirst() }

        let median = recent.sorted()[recent.count / 2]
        if let current = filtered {
            filtered = smoothing * median + (1 - smoothing) * current
        } else {
            filtered = median
        }
        window.removeAll()
        return filtered
    }
}

// MARK: - Health & runtime model

/// Fuses three sources of truth about capacity, in order of trust:
///   1. what this session actually moved (coulomb counting),
///   2. what earlier sessions measured (exponentially decayed),
///   3. what the fuel gauge firmware believes (the prior).
final class BatteryHealthModel {

    private var smoothedPower: Double = 0
    private var variance: Double = 1
    private let measurementNoise: Double = 0.45
    private let processNoise: Double = 0.04

    private var hourlySum = [Double](repeating: 0, count: 24)
    private var hourlyCount = [Int](repeating: 0, count: 24)

    /// Kalman filter over instantaneous power. One call per tick — calling it
    /// twice in a tick double-counts the hourly bucket.
    func smoothPower(_ watts: Double) -> Double {
        let input = max(0.5, abs(watts))
        if smoothedPower == 0 {
            smoothedPower = input
            return smoothedPower
        }
        let predicted = variance + processNoise
        let gain = predicted / (predicted + measurementNoise)
        smoothedPower += gain * (input - smoothedPower)
        variance = (1 - gain) * predicted

        let hour = Calendar.current.component(.hour, from: Date())
        hourlySum[hour] += smoothedPower
        hourlyCount[hour] += 1
        return smoothedPower
    }

    func inferTrueHealth(records: [CalibrationRecord],
                         designCapacityMAh: Double,
                         hardwareMaxCapacityMAh: Double) -> (capacityMAh: Double, healthPercent: Double, confidence: Double) {
        let design = designCapacityMAh > 0 ? designCapacityMAh : 6075
        let prior = hardwareMaxCapacityMAh > 500 ? hardwareMaxCapacityMAh : design
        let valid = records.filter { $0.calculatedCapacityMAh > 500 && $0.batteryHealthPercentage > 0 }

        guard !valid.isEmpty else {
            let health = min(100, max(1, prior / design * 100))
            return (prior, health, 85)
        }

        var totalWeight = 0.0
        var weightedCapacity = 0.0
        for (index, record) in valid.prefix(6).enumerated() {
            let decay = exp(-Double(index) * 0.35)
            let efficiency = record.coulombicEfficiency > 0 ? min(1, record.coulombicEfficiency / 100) : 0.95
            let weight = decay * efficiency
            totalWeight += weight
            weightedCapacity += record.calculatedCapacityMAh * weight
        }

        let measured = totalWeight > 0.0001 ? weightedCapacity / totalWeight : prior
        // Measured sessions lead (65 %), the firmware prior keeps it sane (35 %).
        let blended = measured * 0.65 + prior * 0.35
        let health = min(100, max(1, blended / design * 100))
        return (blended, health, min(99, 85 + Double(valid.count) * 3))
    }

    func remainingMinutes(percentage: Int, voltage: Double, power: Double, fullCapacityMAh: Double) -> Int {
        guard power > 0.5, fullCapacityMAh > 0 else { return 0 }

        let remainingMAh = fullCapacityMAh * Double(percentage) / 100
        // Only a sanity fallback: a 7.6 V two-cell pack must not be forced to 11.4 V.
        let operationalVoltage = (voltage > 5 && voltage < 20) ? voltage : 11.4
        let remainingWh = remainingMAh * operationalVoltage / 1000

        let hour = Calendar.current.component(.hour, from: Date())
        let hourAverage = hourlyCount[hour] > 3 ? hourlySum[hour] / Double(hourlyCount[hour]) : power
        let blended = power * 0.8 + hourAverage * 0.2
        guard blended >= 0.8 else { return 0 }

        return min(1440, max(1, Int(remainingWh / blended * 60)))
    }
}
