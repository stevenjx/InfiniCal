//
//  SleepSession.swift
//  "The lid was closed for eight hours and it lost 8 % — is that normal?"
//
//  `SleepControl` decides whether the machine may sleep. Nothing recorded what
//  actually happened while it did, so the only way to answer that question was
//  a stopwatch and a screenshot before and after.
//
//  The observation window is deliberately narrow: take a sample at
//  `willSleep`, another at `didWake`, and keep the pair. No `pmset -g log`
//  parsing — that reads a system log whose format is not a contract, and the
//  two samples are enough to answer the question that was actually asked.
//
//  Same split as the rest of the codebase: a record, a pure evaluator, and a
//  store. The evaluator is where the honesty lives — a wake that crossed an
//  adapter change or a wake the app never saw produces no drain figure at all.
//

import Foundation

struct SleepSession: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Date
    var end: Date
    var startPercentage: Int
    var endPercentage: Int
    var startTemperature: Double
    var endTemperature: Double
    /// Nil when the machine was on the adapter either before or after — the
    /// pack was not the power source, so the drop is not a drain figure.
    var pluggedThroughout: Bool?
    /// The adapter state changed across the sleep, so the percentage delta
    /// cannot be attributed to standby draw.
    var crossedPowerSource: Bool = false
    /// Wall-clock length of the sleep.
    var sleepSeconds: Double = 0
    /// Percentage points lost. Negative means it gained (was charging).
    var lostPercentage: Int { max(-100, startPercentage - endPercentage) }

    var hours: Double { sleepSeconds / 3600 }
    /// Percentage points per hour. Nil for sessions that cannot support the
    /// claim: too short, or the power source changed underneath.
    var percentPerHour: Double? {
        guard !crossedPowerSource, sleepSeconds >= SleepReport.minimumSleepSeconds,
              hours > 0 else { return nil }
        return Double(lostPercentage) / hours
    }

    var isAbnormal: Bool {
        guard let rate = percentPerHour else { return false }
        return rate > SleepReport.abnormalPercentPerHour
    }
}

/// Seconds below which a sleep is not worth a row: closing the lid to move a
/// laptop across the room produced more rows than real nights did.
enum SleepReport {
    static let minimumSleepSeconds: Double = 600
    /// More than 2 %/h on standby is the point where "something kept waking it"
    /// becomes the likely explanation rather than normal standby draw.
    static let abnormalPercentPerHour: Double = 2.0

    /// Thermal state, used only to describe the sleep, never to judge it.
    static func isHot(_ temperature: Double) -> Bool { temperature >= 35 }
}

enum SleepAnalyzer {

    /// Newest first, bounded by the caller. Pure.
    static func recent(_ sessions: [SleepSession], limit: Int = 14,
                       now: Date = Date()) -> [SleepSession] {
        sessions
            .filter { $0.end <= now && $0.sleepSeconds >= SleepReport.minimumSleepSeconds }
            .sorted { $0.end > $1.end }
            .prefix(limit)
            .map { $0 }
    }

    struct Summary: Equatable {
        var count: Int = 0
        /// Average of usable sessions, nil when none qualified.
        var averagePercentPerHour: Double?
        var worst: SleepSession?
        var totalHours: Double = 0
        /// Sessions excluded from the average because the power source changed.
        var excluded: Int = 0
    }

    static func summarize(_ sessions: [SleepSession], now: Date = Date()) -> Summary {
        let usable = recent(sessions, limit: 60, now: now)
        var summary = Summary(count: usable.count)
        summary.totalHours = usable.reduce(0) { $0 + $1.hours }
        let rates = usable.compactMap { $0.percentPerHour }
        summary.excluded = usable.count - rates.count
        if !rates.isEmpty {
            summary.averagePercentPerHour = rates.reduce(0, +) / Double(rates.count)
        }
        summary.worst = usable.filter { $0.percentPerHour != nil }
            .max { ($0.percentPerHour ?? 0) < ($1.percentPerHour ?? 0) }
        return summary
    }

    /// The one sentence worth putting above the table. It names the likely
    /// cause without claiming to know it: the app can see the drain, not the
    /// wake reason.
    static func advice(_ summary: Summary) -> String? {
        guard summary.count >= 3, let average = summary.averagePercentPerHour else { return nil }
        if average > SleepReport.abnormalPercentPerHour {
            return t("睡眠期间掉电偏快。常见原因是外设供电或后台唤醒；可以拔掉不用的外设，或在「电池」设置里检查哪些 App 允许后台活动。")
        }
        if average < 0.2 {
            return t("睡眠耗电很低，没有需要处理的地方。")
        }
        return nil
    }
}

final class SleepSessionStore: ObservableObject {

    static let shared = SleepSessionStore()

    @Published private(set) var sessions: [SleepSession] = []
    @Published private(set) var readStatus: StoreReadStatus = .clean

    private var dirty = false
    private var safeToRotate = false
    private let retentionDays = 180

    private init() { load() }

    var fileURL: URL {
        CalibrationStore.directory.appendingPathComponent("sleep.json")
    }

    /// True while the machine is asleep — the in-memory pair is the only copy
    /// at that moment, and `willSleep` has to have flushed it.
    func record(_ session: SleepSession) {
        guard session.sleepSeconds >= SleepReport.minimumSleepSeconds else { return }
        sessions.append(session)
        prune()
        dirty = true
        save()
    }

    func clear() {
        sessions = []
        dirty = false
        StoreIO.discard(file: fileURL)
    }

    func acknowledgeReadIssue() { readStatus = .clean }

    func save() {
        guard dirty else { return }
        guard StoreIO.save(sessions, to: fileURL, rotate: safeToRotate) else { return }
        safeToRotate = true
        dirty = false
    }

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        sessions.removeAll { $0.end < cutoff }
    }

    private func load() {
        let read = StoreIO.load(SleepSession.self, from: fileURL)
        sessions = read.value
        readStatus = read.status
        safeToRotate = read.safeToRotate
    }
}