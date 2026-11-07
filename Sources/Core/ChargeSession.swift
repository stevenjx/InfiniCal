//
//  ChargeSession.swift
//  How the pack was actually charged, one plug-in at a time.
//
//  `DailyStat` answers "how much energy moved today". It cannot answer "was this
//  machine left at 100 % on the adapter overnight", because a night at 100 % and
//  a quick top-up to 80 % fold into the same daily total. That difference is the
//  single largest thing a user can change, so it gets its own record.
//
//  Split in three, same as the rest of the codebase:
//    ChargeSession        the record, plain Codable values
//    SessionBuilder       pure state machine: samples in, finished sessions out
//    ChargeHabitAnalyzer  pure rules: sessions in, findings out
//  The store is the only part that touches the disk.
//

import Foundation

// MARK: - Record

struct ChargeSession: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Date
    var end: Date
    var startPercentage: Int
    var endPercentage: Int
    /// Seconds the adapter was connected. Equals `end - start` unless the app
    /// was closed or asleep in the middle.
    var pluggedSeconds: Double = 0
    /// Seconds with a real charge current.
    var chargingSeconds: Double = 0
    /// Seconds at ≥ 99 % while plugged in — the state that ages a pack fastest.
    var fullHoldSeconds: Double = 0
    var temperatureSum: Double = 0
    var temperatureSamples: Int = 0
    var maxTemperature: Double = 0
    /// Energy delivered into the pack, from the measured current.
    var chargeWh: Double = 0
    /// Which lever was holding the ceiling when the session ended.
    var backend: String = ""
    var heatProtectTriggered: Bool = false
    /// The adapter was unplugged and plugged back in during the session.
    var replugged: Bool = false
    /// The process was suspended (sleep / app closed) for more than
    /// `SessionBuilder.gapSeconds` at some point during the session.
    var crossedSleep: Bool = false

    var durationSeconds: Double { max(0, end.timeIntervalSince(start)) }
    var pluggedHours: Double { pluggedSeconds / 3600 }
    var averageTemperature: Double {
        temperatureSamples > 0 ? temperatureSum / Double(temperatureSamples) : 0
    }
    /// Width of the window the session covered. A 5 %-wide session is the
    /// shallow top-up that keeps a pack healthy; a 60 %-wide one is a cycle.
    var spanPercentage: Int { max(0, endPercentage - startPercentage) }
    var fullHoldHours: Double { fullHoldSeconds / 3600 }

    /// Sessions this short carry no habit signal and are not stored.
    static let minimumSeconds: Double = 120
}

// MARK: - Builder

/// Folds samples into sessions.
///
/// Pure and explicit about its two failure modes: a gap in the samples (the
/// process was suspended, so the wall-clock span is larger than what was
/// observed) and a replug in the middle (two sessions, not one). Both are
/// recorded on the session instead of being silently merged or dropped.
struct SessionBuilder {

    /// A sampling gap longer than this means the app was not running, so the
    /// energy moved during the gap was never measured.
    static let gapSeconds: Double = 90

    struct Sample: Equatable {
        var at: Date
        var pluggedIn: Bool
        var charging: Bool
        var percentage: Int
        var temperature: Double
        /// Instantaneous charge power into the pack, watts. Negative ignored.
        var chargeWatts: Double
        var backend: String
        var heatProtect: Bool
    }

    private(set) var current: ChargeSession?
    private var lastSampleAt: Date?
    private var lastPercentage: Int?

    /// Returns a completed session when this sample closed one.
    mutating func ingest(_ sample: Sample) -> ChargeSession? {
        defer {
            lastSampleAt = sample.at
            if sample.pluggedIn { lastPercentage = sample.percentage }
        }

        // A gap inside an open session is not an error: it is what sleeping looks
        // like. Flag it and keep accumulating, because the pack did sit on the
        // adapter for that time even though nothing was sampled.
        if var open = current, let last = lastSampleAt,
           sample.at.timeIntervalSince(last) > Self.gapSeconds {
            open.crossedSleep = true
            current = open
        }

        guard sample.pluggedIn else {
            return close(at: sample.at, percentage: sample.percentage, backend: sample.backend)
        }

        if current == nil {
            var fresh = ChargeSession(start: sample.at, end: sample.at,
                                      startPercentage: sample.percentage,
                                      endPercentage: sample.percentage)
            fresh.backend = sample.backend
            // The opening sample carries no elapsed time, but its flags are
            // observations all the same: a session that begins inside heat
            // protection has to say so.
            applyFlags(&fresh, sample, step: 0)
            current = fresh
            lastPercentage = sample.percentage
            return nil
        }

        guard var open = current else { return nil }
        let step = lastSampleAt.map { min(max(0, sample.at.timeIntervalSince($0)), Self.gapSeconds) } ?? 0
        open.end = sample.at
        open.endPercentage = sample.percentage
        applyFlags(&open, sample, step: step)
        // A percentage that goes *up* mid-session after having gone down means
        // the adapter was pulled and put back while we were not looking.
        if let previous = lastPercentage, sample.percentage < previous - 2,
           open.chargingSeconds > 0 {
            open.replugged = true
        }
        current = open
        return nil
    }

    /// Everything a sample contributes apart from the wall-clock bookkeeping.
    private func applyFlags(_ open: inout ChargeSession, _ sample: Sample, step: Double) {
        if step > 0 {
            open.pluggedSeconds += step
            if sample.charging { open.chargingSeconds += step }
            if sample.percentage >= 99 { open.fullHoldSeconds += step }
            if sample.chargeWatts > 0 { open.chargeWh += sample.chargeWatts * step / 3600 }
        }
        if sample.temperature > 0, sample.temperature < 120 {
            open.temperatureSum += sample.temperature
            open.temperatureSamples += 1
            open.maxTemperature = max(open.maxTemperature, sample.temperature)
        }
        if sample.heatProtect { open.heatProtectTriggered = true }
        if !sample.backend.isEmpty { open.backend = sample.backend }
    }

    /// Closes whatever is open. Called when the adapter comes out and on quit.
    ///
    /// The threshold is judged on the wall-clock span, not on `pluggedSeconds`:
    /// the first sample opens the session, so a 6 s plug-in has only 4 s of
    /// accumulated steps and would be dropped even though it was observed.
    mutating func close(at date: Date, percentage: Int, backend: String = "") -> ChargeSession? {
        guard var open = current else { return nil }
        current = nil
        open.end = date
        open.endPercentage = percentage
        if !backend.isEmpty { open.backend = backend }
        guard open.durationSeconds >= ChargeSession.minimumSeconds else { return nil }
        return open
    }

    /// Discards the open session without emitting it (history cleared).
    mutating func reset() {
        current = nil
        lastSampleAt = nil
        lastPercentage = nil
    }
}

// MARK: - Analysis

struct ChargeHabitFinding: Identifiable, Equatable {
    enum Kind: String {
        /// Time spent parked at 100 % on the adapter.
        case fullHold
        /// Many cycles that went from near-empty to full.
        case deepCycle
        /// Charging at or above 40 °C.
        case hotCharge
        /// Mostly short top-ups — positive feedback, not a warning.
        case shallowTopUp
    }

    var kind: Kind
    var title: String
    var advice: String
    var evidence: [String]
    /// Positive findings are shown with the same weight but not as a problem.
    var isPositive: Bool = false

    var id: String { kind.rawValue }
}

enum ChargeHabitAnalyzer {

    /// Numbers chosen so the advice only fires when the behaviour is habitual.
    /// One long night a month is not a habit; eight of them is.
    static let windowDays = 30
    static let fullHoldHours = 20.0
    static let deepCycleCount = 10
    static let deepCycleFrom = 15
    static let deepCycleTo = 95
    static let hotChargeHours = 5.0
    static let hotTemperature = 40.0
    static let shallowShare = 0.7
    static let shallowSpan = 25
    static let minimumSessions = 5

    struct Report: Equatable {
        var findings: [ChargeHabitFinding] = []
        var sessions: [ChargeSession] = []
        var windowStart: Date
        /// Days of history the rules actually saw; the UI says "还需要 N 天"
        /// below `minimumDays`.
        var observedDays: Int = 0
        static let minimumDays = 7
    }

    static func analyze(_ sessions: [ChargeSession], now: Date = Date(),
                        calendar: Calendar = .current) -> Report {
        let start = now.addingTimeInterval(-Double(windowDays) * 86400)
        let window = sessions
            .filter { $0.end >= start && $0.end <= now && $0.pluggedSeconds > 0 }
            .sorted { $0.end < $1.end }
        var report = Report(sessions: window.reversed(), windowStart: start)
        report.observedDays = Set(window.map { calendar.startOfDay(for: $0.end) }).count

        guard report.observedDays >= Report.minimumDays, window.count >= minimumSessions else {
            return report
        }

        if let finding = fullHold(window) { report.findings.append(finding) }
        if let finding = deepCycles(window) { report.findings.append(finding) }
        if let finding = hotCharging(window) { report.findings.append(finding) }
        if let finding = shallowTopUp(window) { report.findings.append(finding) }
        // Positive feedback last: it is the least urgent line on the card.
        report.findings.sort { lhs, rhs in
            if lhs.isPositive != rhs.isPositive { return !lhs.isPositive }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return report
    }

    /// Time parked at full is the clearest actionable number in the whole app:
    /// the fix is one slider, and the effect on calendar ageing is real.
    private static func fullHold(_ sessions: [ChargeSession]) -> ChargeHabitFinding? {
        let hours = sessions.reduce(0) { $0 + $1.fullHoldHours }
        guard hours >= fullHoldHours else { return nil }
        let nights = sessions.filter { $0.fullHoldSeconds > 0 }.count
        return ChargeHabitFinding(
            kind: .fullHold,
            title: t("满电静置时间偏长"),
            advice: t("把充电上限设到 80% 并保持自动放电；需要满电时再用一次性充满。"),
            evidence: [
                tf("近 30 天有 {p} 小时处于满电且插电状态", String(format: "%.1f", hours)),
                tf("分布在 {p} 次插电会话中", "\(nights)"),
                t("满电静置会加快容量衰减；80% 左右的静置压力明显更小。"),
            ])
    }

    /// A deep cycle is not harmful per se — it is waste when it is frequent.
    private static func deepCycles(_ sessions: [ChargeSession]) -> ChargeHabitFinding? {
        let deep = sessions.filter {
            $0.startPercentage <= deepCycleFrom && $0.endPercentage >= deepCycleTo
        }
        guard deep.count >= deepCycleCount else { return nil }
        let peak = deep.map(\.maxTemperature).max() ?? 0
        return ChargeHabitFinding(
            kind: .deepCycle,
            title: t("深度充放次数较多"),
            advice: t("日常保持 80% 上限，把完整的 0–100% 循环留给校准和出行前。"),
            evidence: [
                tf("近 30 天有 {p} 次从 ≤{p}% 充到 ≥{p}%",
                   "\(deep.count)", "\(deepCycleFrom)", "\(deepCycleTo)"),
                tf("这些会话最高温度 {p}°C", String(format: "%.0f", peak)),
                t("每一次完整循环都会消耗一次循环寿命；浅充浅放可以用更少的循环走同样的路。"),
            ])
    }

    private static func hotCharging(_ sessions: [ChargeSession]) -> ChargeHabitFinding? {
        let hours = sessions.reduce(0.0) { total, session in
            // Only time actually charging counts, and only the part of it above
            // the threshold: a session that touched 41 °C once is not five hours.
            guard session.averageTemperature >= hotTemperature else { return total }
            return total + session.chargingSeconds / 3600
        }
        guard hours >= hotChargeHours else { return nil }
        return ChargeHabitFinding(
            kind: .hotCharge,
            title: t("高温时段充电时间偏长"),
            advice: t("开启过热保护，并把充电安排在通风处；边充边跑重负载时先暂停充电。"),
            evidence: [
                tf("近 30 天有 {p} 小时在平均 ≥{p}°C 时充电",
                   String(format: "%.1f", hours), String(format: "%.0f", hotTemperature)),
                t("高温充电同时加速容量衰减与内阻上升。"),
            ])
    }

    /// Shallow top-ups are what a healthy habit looks like; saying so is what
    /// makes the rest of the list credible.
    ///
    /// Ending near full is excluded on purpose. An 80 → 100 % session has a
    /// narrow span but is the opposite of a shallow top-up: it parks the pack at
    /// 100 % every time, which is exactly what `fullHold` is there to flag.
    /// Counting it here would praise the behaviour it should warn about.
    private static func shallowTopUp(_ sessions: [ChargeSession]) -> ChargeHabitFinding? {
        let filled = sessions.filter { $0.spanPercentage > 0 && $0.endPercentage < 95 }
        guard filled.count >= minimumSessions else { return nil }
        let shallow = filled.filter { $0.spanPercentage < shallowSpan }
        let share = Double(shallow.count) / Double(filled.count)
        guard share >= shallowShare else { return nil }
        let median = medianSpan(filled)
        return ChargeHabitFinding(
            kind: .shallowTopUp,
            title: t("以浅充浅放为主"),
            advice: t("保持现在的用法即可；不需要为了「校准」频繁做完整循环。"),
            evidence: [
                tf("近 30 天 {p} 次会话中有 {p} 次充电区间小于 {p}%",
                   "\(filled.count)", "\(shallow.count)", "\(shallowSpan)"),
                tf("充电区间中位数 {p}%", "\(median)"),
            ],
            isPositive: true)
    }

    /// Median of the span across sessions; used instead of the mean so one full
    /// cycle does not move the "typical session" line.
    static func medianSpan(_ sessions: [ChargeSession]) -> Int {
        let spans = sessions.map(\.spanPercentage).sorted()
        guard !spans.isEmpty else { return 0 }
        return spans[spans.count / 2]
    }
}

// MARK: - Store

/// `sessions.json`, same recovery rules as the other stores.
final class ChargeSessionStore: ObservableObject {

    static let shared = ChargeSessionStore()

    @Published private(set) var sessions: [ChargeSession] = []
    @Published private(set) var readStatus: StoreReadStatus = .clean

    private let calendar = Calendar.current
    private var dirty = false
    private var safeToRotate = false
    /// 180 days, as planned: enough for a seasonal comparison without letting
    /// the file grow without bound (a heavy day is ~6 sessions).
    private let retentionDays = 180

    private init() { load() }

    var fileURL: URL {
        CalibrationStore.directory.appendingPathComponent("sessions.json")
    }

    /// The plug-in session still in progress.
    ///
    /// A session can last all night. Keeping it only in memory meant a crash,
    /// a force-quit or a power loss discarded the whole thing — the one record
    /// that answers "was this machine parked at 100 % overnight". It is written
    /// to its own file, replaced in place, and folded into `sessions` on the
    /// next launch.
    var liveURL: URL {
        CalibrationStore.directory.appendingPathComponent("session-live.json")
    }

    func record(_ session: ChargeSession) {
        sessions.append(session)
        prune()
        dirty = true
        // The session just closed, so the live snapshot is stale.
        clearLive()
    }

    /// Called periodically while a session is open. Cheap: one small object.
    func saveLive(_ session: ChargeSession?) {
        guard let session else { return clearLive() }
        guard session.pluggedSeconds >= ChargeSession.minimumSeconds else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: liveURL, options: .atomic)
    }

    func clearLive() {
        try? FileManager.default.removeItem(at: liveURL)
    }

    func clear() {
        sessions = []
        dirty = false
        StoreIO.discard(file: fileURL)
        clearLive()
    }

    func acknowledgeReadIssue() { readStatus = .clean }

    func save() {
        guard dirty else { return }
        guard StoreIO.save(sessions, to: fileURL, rotate: safeToRotate) else { return }
        safeToRotate = true
        dirty = false
    }

    private func prune() {
        let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date.distantPast
        guard let firstKept = sessions.firstIndex(where: { $0.end >= cutoff }) else {
            sessions.removeAll()
            return
        }
        if firstKept > 0 { sessions.removeFirst(firstKept) }
    }

    private func load() {
        let read = StoreIO.load(ChargeSession.self, from: fileURL)
        sessions = read.value
        readStatus = read.status
        safeToRotate = read.safeToRotate
        recoverLive()
    }

    /// Folds a session left behind by the previous process into the store.
    ///
    /// The end time is the last sample, which is what actually happened — a
    /// session that ended because the Mac lost power has no later evidence and
    /// claiming it ran until the relaunch would invent hours of charging.
    private func recoverLive() {
        guard let data = try? Data(contentsOf: liveURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        defer { clearLive() }
        guard let session = try? decoder.decode(ChargeSession.self, from: data),
              session.pluggedSeconds >= ChargeSession.minimumSeconds,
              session.end > session.start,
              session.end <= Date().addingTimeInterval(60) else { return }
        sessions.append(session)
        sessions.sort { $0.end < $1.end }
        prune()
        dirty = true
    }
}