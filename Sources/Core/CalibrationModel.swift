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

    /// Timestamps are unique inside a session, so they double as identity: a
    /// decimated rebuild of the array does not invalidate every row in the UI.
    var id: Date { timestamp }
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
            .filter { $0.calculatedCapacityMAh > 1000 && $0.batteryHealthPercentage > 0 }
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
