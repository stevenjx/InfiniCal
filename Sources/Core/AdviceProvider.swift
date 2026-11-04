//
//  AdviceProvider.swift
//  Maps the stored history onto the plain values the advice engine expects.
//
//  Keeping the mapping here means the rules stay testable without a battery,
//  a disk or a calibration run.
//

import Foundation

enum AdviceProvider {

    static func input(days: [DailyStat], records: [CalibrationRecord],
                      chargeLimit: Int, now: Date = Date()) -> AdviceInput {
        AdviceInput(days: days.map { day in
            AdviceInput.Day(date: day.day,
                            highTemperatureSeconds: day.highTemperatureSeconds ?? 0,
                            maxTemperature: day.maxTemperature,
                            maxPercentage: day.maxPercentage,
                            pluggedSeconds: day.pluggedSeconds,
                            observedSeconds: day.observedSeconds ?? 0)
        }, sessions: records.map { record in
            AdviceInput.Session(date: record.endDate,
                                capacityMAh: record.calculatedCapacityMAh,
                                resistanceMilliohm: record.internalResistanceMilliohm,
                                healthPercent: record.batteryHealthPercentage,
                                cycleCount: record.cycleCount,
                                preset: record.conditions?.preset,
                                startPercentage: record.startDischargePercentage,
                                eligible: record.quality?.eligibleForAggregation == true)
        }, chargeLimit: chargeLimit, now: now)
    }

    static func report(days: [DailyStat], records: [CalibrationRecord],
                       chargeLimit: Int, now: Date = Date()) -> AdviceReport {
        AdviceEngine.evaluate(input(days: days, records: records, chargeLimit: chargeLimit, now: now))
    }
}
