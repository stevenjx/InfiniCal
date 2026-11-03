//
//  CalibrationModel.swift
//  Data produced by a calibration session: samples, records, history storage.
//
//  Nothing here talks to the SMC or to the UI — it is the shape of the data the
//  engine measures and the panel displays, plus the on-disk format used to keep
//  past sessions between launches.
//

import Foundation

/// Crash-recovery journal, deliberately separate from completed health records.
/// Integration buckets are never resumed across an unobserved interval.
struct CalibrationCheckpoint: Codable, Equatable {
    var schemaVersion = 1
    var sessionID: UUID
    var phase: String
    var startedAt: Date
    var lastSampleAt: Date
    var targetPercentage: Int
    var restoreLimit: Int
    var stressMode: String
    var adapterControl: String?
    var chargeControl: String
    var reason: String
    /// nil for journals written before calibration presets existed.
    var preset: String? = nil
}

/// One 1 Hz telemetry sample taken during a calibration session.
struct CalibrationSample: Identifiable {
    let timestamp: Date
    let percentage: Double
    let power: Double
    let voltage: Double
    let amperage: Double
    let temperature: Double

    /// SoC (CPU + GPU + ANE) draw from powermetrics. Zero when no source could
    /// produce it — the quality field says which case this is.
    var socPower: Double = 0
    var socPowerQuality: PowerQuality = .unavailable

    /// Display backlight draw. No platform exposes this as a sensor, so it is
    /// always a model output and always labelled as one.
    var displayPower: Double = 0
    var displayPowerQuality: PowerQuality = .unavailable

    /// Millivolt spread between the highest and the lowest cell at this sample.
    /// Zero when the pack exposes no per-cell voltages, so the chart can tell
    /// "cells are balanced" apart from "this pack does not report cells".
    var cellDeltaMillivolts: Double = 0

    /// Timestamps are unique inside a session, so they double as identity: a
    /// decimated rebuild of the array does not invalidate every row in the UI.
    var id: Date { timestamp }
}

/// Evidence quality, not a probability or a laboratory accuracy claim.
struct CalibrationQuality: Codable, Equatable {
    enum Grade: String, Codable { case high, medium, low, invalid }
    let grade: Grade
    let reasons: [String]
    let completedPhases: [String]
    let negativeSamples: Int
    let positiveSamples: Int
    let backend: String

    static func evaluate(phases: Set<String>, negativeSamples: Int, positiveSamples: Int,
                         dischargeAh: Double, rechargeAh: Double, span: Int,
                         issues: Set<String>, backend: String, completed: Bool,
                         presetCapped: Bool = false) -> Self {
        let required: Set<String> = ["chargingToFull", "discharging", "rechargingToFull", "holdingAtFull", "dischargingToBuffer"]
        var reasons = issues
        if !completed || !required.isSubset(of: phases) { reasons.insert("阶段未完整完成") }
        if negativeSamples < 30 || positiveSamples < 30 { reasons.insert("有效电流样本不足") }
        if !dischargeAh.isFinite || !rechargeAh.isFinite || dischargeAh <= 0 || rechargeAh <= 0 {
            reasons.insert("缺少有效充放电积分")
        }
        if span < 50 { reasons.insert("测量电量跨度不足 50%") }
        // A quick-check run measures a smaller slice on purpose; say why the
        // grade is capped rather than implying the run went wrong.
        if presetCapped { reasons.insert("快速检查模式，未做完整深度放电") }
        let invalid = !completed || !required.isSubset(of: phases)
            || negativeSamples < 30 || positiveSamples < 30
            || !dischargeAh.isFinite || !rechargeAh.isFinite || dischargeAh <= 0 || rechargeAh <= 0
        let grade: Grade = invalid ? .invalid
            : (presetCapped || span < 50 || issues.contains("采样中断") ? .low : (reasons.isEmpty ? .high : .medium))
        return Self(grade: grade, reasons: reasons.sorted(), completedPhases: phases.sorted(),
                    negativeSamples: negativeSamples, positiveSamples: positiveSamples, backend: backend)
    }

    var label: String {
        switch grade {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        case .invalid: return "无效"
        }
    }
    var eligibleForAggregation: Bool { grade == .high || grade == .medium }
}

struct CalibrationConditions: Codable, Equatable {
    let model: String
    let backend: String
    let stressMode: String
    let target: Int
    let startPercentage: Int
    let meanTemperature: Double
    let meanPower: Double
    let designCapacityMAh: Double
    /// Calibration depth this record was produced with. nil on legacy records.
    var preset: String? = nil

    func matches(_ other: Self) -> Bool {
        guard meanTemperature.isFinite, other.meanTemperature.isFinite,
              meanTemperature > 0, other.meanTemperature > 0,
              meanPower.isFinite, other.meanPower.isFinite, meanPower > 0, other.meanPower > 0,
              designCapacityMAh > 0, other.designCapacityMAh > 0,
              model != "--" else { return false }
        return model == other.model && backend == other.backend && stressMode == other.stressMode
            && target == other.target && abs(startPercentage - other.startPercentage) <= 2
            && abs(meanTemperature - other.meanTemperature) <= 3
            && abs(meanPower - other.meanPower) / max(meanPower, other.meanPower) <= 0.2
            && abs(designCapacityMAh - other.designCapacityMAh) / max(designCapacityMAh, other.designCapacityMAh) <= 0.02
    }
}

struct CalibrationPhaseEvent: Codable {
    let phase: String
    let date: Date
}

/// Explicit allowlist: no serials, paths, process names, arbitrary logs or errors.
struct CalibrationExport: Codable {
    struct Sample: Codable {
        let timestamp: Date
        let phase: String
        let percentage: Double
        let voltage: Double
        let amperage: Double
        let temperature: Double
        let power: Double
    }
    let schemaVersion: Int
    let generatedAt: Date
    let completed: Bool
    let backend: String
    let helperProtocol: Int
    let model: String
    let capabilities: [String]
    let measuredCapacityMAh: Double?
    let measuredCapacityWh: Double?
    let healthPercentage: Double?
    let sampleCount: Int
    let droppedSamples: Int
    let quality: CalibrationQuality?
    let conditions: CalibrationConditions?
    let timeline: [CalibrationPhaseEvent]
    let samples: [Sample]

    var csv: String {
        "Timestamp,Phase,Percentage,Voltage(V),Amperage(A),Temperature(C),Power(W)\n"
            + samples.map { "\($0.timestamp.ISO8601Format()),\($0.phase),\($0.percentage),\($0.voltage),\($0.amperage),\($0.temperature),\($0.power)" }.joined(separator: "\n")
    }
}

/// Result of one completed session. Everything is measured, nothing is copied
/// from a third-party app.
struct CalibrationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var startDate = Date()
    var endDate = Date()
    var startDischargePercentage = 0
    var cycleCount = 0
    var designCapacityMAh: Double = 0
    var calculatedCapacityMAh: Double = 0
    var calculatedCapacityWh: Double = 0
    var batteryHealthPercentage: Double = 0
    var dischargeEnergyWh: Double = 0
    var dischargeEnergyAh: Double = 0
    var rechargeEnergyWh: Double = 0
    var rechargeEnergyAh: Double = 0
    var coulombicEfficiency: Double = 0
    var internalResistanceMilliohm: Double = 0
    var reportFilePath: String? = nil
    /// nil means legacy record: quality was not assessed, never assume high.
    var quality: CalibrationQuality? = nil
    var conditions: CalibrationConditions? = nil
}

/// Weighted blend of the most recent sessions.
struct AggregatedHealth {
    var sessionCount = 0
    var capacityMAh: Double = 0
    var capacityWh: Double = 0
    var healthPercent: Double = 0
    var confidence: Double = 0
}

enum CalibrationStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfiniCal", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var fileURL: URL { directory.appendingPathComponent("calibration.json") }

    static func load() -> [CalibrationRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CalibrationRecord].self, from: data)) ?? []
    }

    static func save(_ records: [CalibrationRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func append(_ record: CalibrationRecord) -> [CalibrationRecord] {
        var records = load()
        records.insert(record, at: 0)
        save(records)
        return records
    }

    static func delete(id: UUID) -> [CalibrationRecord] {
        let records = load().filter { $0.id != id }
        save(records)
        return records
    }

    static func clear() {
        save([])
    }

    /// Multi-session blend: the newest five valid sessions, weighted by recency.
    static func aggregate(_ records: [CalibrationRecord]) -> AggregatedHealth? {
        let valid = records
            .filter { $0.calculatedCapacityMAh > 1000 && $0.batteryHealthPercentage > 0 && $0.quality?.eligibleForAggregation == true }
            .sorted { $0.startDate > $1.startDate }
        guard !valid.isEmpty else { return nil }

        let recent = Array(valid.prefix(5))
        var totalWeight = 0.0
        var capacity = 0.0
        var energy = 0.0
        var health = 0.0
        for (index, record) in recent.enumerated() {
            let weight = Double(recent.count - index)
            totalWeight += weight
            capacity += record.calculatedCapacityMAh * weight
            energy += record.calculatedCapacityWh * weight
            health += record.batteryHealthPercentage * weight
        }
        guard totalWeight > 0 else { return nil }

        let confidenceTable: [Double] = [0, 60, 80, 90, 95, 99]
        return AggregatedHealth(sessionCount: recent.count,
                                capacityMAh: capacity / totalWeight,
                                capacityWh: energy / totalWeight,
                                healthPercent: health / totalWeight,
                                confidence: confidenceTable[min(recent.count, 5)])
    }
}
