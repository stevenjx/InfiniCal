//
//  Migration.swift
//  Moving a battery's history to another Mac, and putting two machines side by side.
//
//  Everything this app knows is local, which is the point — but "local" became
//  "trapped" the moment someone replaced a laptop. The archive is the way out:
//  one file, versioned, with an explicit merge rule for every kind of record.
//
//  Format note: the plan said "zip with JSON inside". It is a single JSON
//  document instead. Reasons: macOS 12 has no Foundation zip API (only
//  Compression's raw streams), a zip hides the contents from anyone who wants
//  to look, and a 400-day archive is under a megabyte anyway. The extension
//  still marks it as ours, and `format` + `version` still make it refuse
//  anything it does not understand.
//
//  Merge rule, one line: never overwrite a local record, never silently drop an
//  incoming one. Duplicates are counted and reported.
//

import Foundation

// MARK: - Archive

/// A machine's identity as far as a comparison is concerned: no serial number,
/// no user name, just the model code and the numbers worth comparing.
struct MachineSummary: Codable, Equatable, Identifiable {
    var id: String { "\(model)-\(exportedAt.timeIntervalSince1970)" }
    var model: String
    var exportedAt: Date
    var healthPercent: Int
    var cycleCount: Int
    var designCapacityMAh: Int
    var maxCapacityMAh: Int
    var appVersion: String
}

struct MigrationArchive: Codable, Equatable {
    static let currentFormat = "infinical.archive"
    static let currentVersion = 1

    var format = MigrationArchive.currentFormat
    var version = MigrationArchive.currentVersion
    var exportedAt = Date()
    var machine: MachineSummary
    var days: [DailyStat] = []
    var calibration: [CalibrationRecord] = []
    var sessions: [ChargeSession] = []
    var sleeps: [SleepSession] = []
    /// Only settings that describe intent, never machine identity or paths.
    var settings: [String: Int] = [:]
    var fanPresets: [FanPreset] = []
    var rules: CapabilityRuleLibrary?
}

/// What an import did. Every number here is shown to the user: "imported 120
/// days" and "skipped 3 duplicates" are two different, equally useful facts.
struct MigrationImportResult: Equatable {
    var daysAdded = 0
    var daysSkipped = 0
    var calibrationsAdded = 0
    var calibrationsSkipped = 0
    var sessionsAdded = 0
    var sessionsSkipped = 0
    var sleepsAdded = 0
    var sleepsSkipped = 0
    var presetsAdded = 0
    var presetsReplaced = 0
    var rulesInstalled = false
    var machine: MachineSummary?

    var totalAdded: Int {
        daysAdded + calibrationsAdded + sessionsAdded + sleepsAdded + presetsAdded
    }

    var summary: String {
        var parts: [String] = []
        if daysAdded > 0 { parts.append(tf("新增 {p} 天", "\(daysAdded)")) }
        if calibrationsAdded > 0 { parts.append(tf("新增 {p} 条校准", "\(calibrationsAdded)")) }
        if sessionsAdded > 0 { parts.append(tf("新增 {p} 次插电会话", "\(sessionsAdded)")) }
        if sleepsAdded > 0 { parts.append(tf("新增 {p} 次睡眠", "\(sleepsAdded)")) }
        if presetsAdded + presetsReplaced > 0 {
            parts.append(tf("预设 +{p} / 覆盖 {p}", "\(presetsAdded)", "\(presetsReplaced)"))
        }
        if rulesInstalled { parts.append(t("已安装规则库")) }
        let skipped = daysSkipped + calibrationsSkipped + sessionsSkipped + sleepsSkipped
        if skipped > 0 { parts.append(tf("跳过 {p} 条重复记录", "\(skipped)")) }
        return parts.isEmpty ? t("没有可导入的新内容") : parts.joined(separator: "，")
    }
}

enum MigrationError: Error, Equatable {
    case notAnArchive
    case newerVersion(Int)
    case empty

    var message: String {
        switch self {
        case .notAnArchive: return t("这不是 InfiniCal 的迁移包")
        case .newerVersion(let value): return tf("迁移包版本 {p} 比当前版本新，请先更新 InfiniCal", "\(value)")
        case .empty: return t("迁移包里没有数据")
        }
    }
}

// MARK: - Pure merge

enum Migration {

    /// Settings worth carrying: intent, not identity. Deliberately excludes
    /// anything that names a machine, a path or a login item.
    static let settingKeys = [
        "chargeVal", "allowChargeLimitsBelow80", "automaticDischarge", "sailingMode",
        "sailingLevel", "heatProtectMode", "maxTemperature", "calibrationBackupPercentage",
        "smartChargeEnabled", "smartChargeHour", "smartChargeMinute", "scenarioDesktop",
        "scenarioBoost", "scenarioNight", "lowPowerLeadMinutes", "dashboardBackgroundUpdates"
    ]

    static func encode(_ archive: MigrationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) -> Result<MigrationArchive, MigrationError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(MigrationArchive.self, from: data) else {
            return .failure(.notAnArchive)
        }
        guard archive.format == MigrationArchive.currentFormat else { return .failure(.notAnArchive) }
        guard archive.version <= MigrationArchive.currentVersion else {
            return .failure(.newerVersion(archive.version))
        }
        guard !archive.days.isEmpty || !archive.calibration.isEmpty
            || !archive.sessions.isEmpty || !archive.sleeps.isEmpty || !archive.fanPresets.isEmpty else {
            return .failure(.empty)
        }
        return .success(archive)
    }

    /// Merges by identity, never by position.
    ///
    /// Days are keyed by the start of the day: a day is a single row by
    /// definition, so two rows for the same day cannot both be kept — the local
    /// one wins and the conflict is counted. Everything else has a UUID and is
    /// simply unioned.
    static func merge(_ incoming: MigrationArchive,
                      into days: [DailyStat],
                      calibration: [CalibrationRecord],
                      sessions: [ChargeSession],
                      sleeps: [SleepSession],
                      fanPresets: [FanPreset]) -> (result: MigrationImportResult,
                                                   days: [DailyStat],
                                                   calibration: [CalibrationRecord],
                                                   sessions: [ChargeSession],
                                                   sleeps: [SleepSession],
                                                   presets: [FanPreset]) {
        var result = MigrationImportResult()
        result.machine = incoming.machine

        let calendar = Calendar.current
        var dayMap = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.day), $0) })
        for day in incoming.days {
            let key = calendar.startOfDay(for: day.day)
            if dayMap[key] != nil {
                result.daysSkipped += 1
            } else {
                dayMap[key] = day
                result.daysAdded += 1
            }
        }
        let mergedDays = dayMap.values.sorted { $0.day < $1.day }

        var calibrationMap = Dictionary(uniqueKeysWithValues: calibration.map { ($0.id, $0) })
        for record in incoming.calibration {
            if calibrationMap[record.id] != nil {
                result.calibrationsSkipped += 1
            } else {
                calibrationMap[record.id] = record
                result.calibrationsAdded += 1
            }
        }
        let mergedCalibration = calibrationMap.values.sorted { $0.endDate > $1.endDate }

        var sessionIDs = Set(sessions.map(\.id))
        var mergedSessions = sessions
        for session in incoming.sessions {
            if sessionIDs.contains(session.id) {
                result.sessionsSkipped += 1
            } else {
                sessionIDs.insert(session.id)
                mergedSessions.append(session)
                result.sessionsAdded += 1
            }
        }
        mergedSessions.sort { $0.end < $1.end }

        var sleepIDs = Set(sleeps.map(\.id))
        var mergedSleeps = sleeps
        for sleep in incoming.sleeps {
            if sleepIDs.contains(sleep.id) {
                result.sleepsSkipped += 1
            } else {
                sleepIDs.insert(sleep.id)
                mergedSleeps.append(sleep)
                result.sleepsAdded += 1
            }
        }
        mergedSleeps.sort { $0.end < $1.end }

        let presetMerge = FanPresetIO.merge(incoming.fanPresets, into: fanPresets)
        result.presetsAdded = presetMerge.added
        result.presetsReplaced = presetMerge.replaced

        return (result, mergedDays, mergedCalibration, mergedSessions, mergedSleeps, presetMerge.result)
    }
}

/// Reading the live machine's identity. Kept out of `Migration` so the merge
/// rules stay a pure function with no `AppState` in their dependency graph.
extension MachineSummary {
    static func current(appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        now: Date = Date()) -> MachineSummary {
        let snapshot = AppState.shared.snapshot
        return MachineSummary(model: SysInfo.machineModel(),
                              exportedAt: now,
                              healthPercent: snapshot.healthPercent,
                              cycleCount: snapshot.cycleCount,
                              designCapacityMAh: snapshot.designCapacity,
                              maxCapacityMAh: snapshot.maxCapacity,
                              appVersion: appVersion)
    }
}

// MARK: - Other machines

/// Summaries of machines whose archive was imported. Kept small on purpose:
/// the point is "this other Mac's pack is at 91 % after 210 cycles", not a
/// second copy of its history.
final class ImportedMachineStore: ObservableObject {

    static let shared = ImportedMachineStore()

    @Published private(set) var machines: [MachineSummary] = []

    private let fileURL: URL

    private init() {
        fileURL = CalibrationStore.directory.appendingPathComponent("machines.json")
        load()
    }

    func add(_ machine: MachineSummary) {
        // Same model exported twice replaces the older summary: a machine has
        // one current health, and keeping every import would turn this list
        // into a changelog nobody asked for.
        machines.removeAll { $0.model == machine.model }
        machines.append(machine)
        machines.sort { $0.exportedAt > $1.exportedAt }
        save()
    }

    func removeAll() {
        machines = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(machines) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        machines = (try? decoder.decode([MachineSummary].self, from: data)) ?? []
    }
}