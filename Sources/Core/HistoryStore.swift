//
//  HistoryStore.swift
//  Long-term battery history, aggregated per calendar day.
//
//  `history.json` only keeps the last three hours so the dashboard charts stay
//  cheap. That is the right shape for a sparkline and the wrong shape for
//  "how much energy did this machine move last month". This store folds the same
//  2 Hz telemetry into one row per day and keeps a year of it.
//

import Foundation

struct DailyStat: Codable, Identifiable, Equatable {
    /// Start of the day, in the current calendar.
    var day: Date
    var chargeWh: Double = 0
    var dischargeWh: Double = 0
    var temperatureSum: Double = 0
    var temperatureSamples: Int = 0
    var maxTemperature: Double = 0
    var minPercentage: Int = 100
    var maxPercentage: Int = 0
    var pluggedSeconds: Double = 0
    var lastHealthPercent: Int = 0
    var cycleCount: Int = 0
    // Optional fields keep pre-trend history decodable. Unknown is not zero.
    var reportedCapacityMAh: Int? = nil
    var observedSeconds: Double? = nil
    var highTemperatureSeconds: Double? = nil
    /// Energy out per hour of the day (0…23), measured. 24 doubles = 192 B a
    /// day, which is what makes a usage profile possible without a second store.
    var hourDischargeWh: [Double]? = nil
    /// Seconds on the adapter per hour of the day. A profile hour with the
    /// adapter connected is not a discharge sample and is excluded.
    var hourPluggedSeconds: [Double]? = nil
    /// Seconds the app actually sampled per hour of the day, so an hour the
    /// machine was asleep is not read as "zero consumption".
    var hourObservedSeconds: [Double]? = nil

    var id: Date { day }
    var averageTemperature: Double {
        temperatureSamples > 0 ? temperatureSum / Double(temperatureSamples) : 0
    }
    var pluggedHours: Double { pluggedSeconds / 3600 }
    /// True for a day the app never saw; used to draw gaps instead of zeros.
    var isEmpty: Bool { temperatureSamples == 0 && chargeWh == 0 && dischargeWh == 0 }
}

// MARK: - Trend

/// Least-squares trend of reported health against cycle count, plus the
/// two-segment comparison that answers "is the decay speeding up?".
///
/// Deliberately not a model. With a few hundred daily rows and a 1 % health
/// resolution, a straight line and its confidence interval are all the data can
/// support, and every number here can be recomputed by hand.
struct BatteryTrend {
    var sampleCount = 0
    var cycleSpan = 0
    /// Percentage points per 100 cycles; negative means capacity is being lost.
    var slopePer100Cycles = 0.0
    /// Half-width of the 95 % confidence interval on the slope.
    var slopeMargin = 0.0
    var rSquared = 0.0
    var currentHealth = 0.0
    var currentCycles = 0
    /// Cycles until health reaches `threshold`, from the fitted line.
    var cyclesToThreshold: Int?
    var threshold = 80.0
    /// Slope over the most recent third of the samples.
    var recentSlopePer100Cycles = 0.0
    var isAccelerating = false

    /// Below this the 1 % integer resolution of the reported health dominates
    /// the fit, so no slope is published at all.
    static let minimumSamples = 8
    static let minimumCycleSpan = 20

    static func compute(days: [DailyStat], threshold: Double = 80) -> BatteryTrend? {
        // One health value per cycle count: many days share a cycle, and
        // counting each day would weight idle weeks more heavily than busy ones.
        var byCycle: [Int: (sum: Double, count: Int)] = [:]
        for day in days where day.lastHealthPercent > 0 && day.cycleCount > 0 {
            let entry = byCycle[day.cycleCount] ?? (0, 0)
            byCycle[day.cycleCount] = (entry.sum + Double(day.lastHealthPercent), entry.count + 1)
        }
        let points = byCycle
            .map { (cycle: $0.key, health: $0.value.sum / Double($0.value.count)) }
            .sorted { $0.cycle < $1.cycle }
        guard points.count >= minimumSamples,
              let first = points.first, let last = points.last,
              last.cycle - first.cycle >= minimumCycleSpan,
              let fit = leastSquares(points) else { return nil }

        var trend = BatteryTrend()
        trend.sampleCount = points.count
        trend.cycleSpan = last.cycle - first.cycle
        trend.slopePer100Cycles = fit.slope * 100
        trend.slopeMargin = fit.margin * 100
        trend.rSquared = fit.rSquared
        trend.currentHealth = last.health
        trend.currentCycles = last.cycle
        trend.threshold = threshold

        if fit.slope < 0 {
            let target = (threshold - fit.intercept) / fit.slope
            let remaining = target - Double(last.cycle)
            trend.cyclesToThreshold = remaining > 0 ? Int(remaining.rounded()) : 0
        }

        let recentCount = max(3, points.count / 3)
        if let recent = leastSquares(Array(points.suffix(recentCount))) {
            trend.recentSlopePer100Cycles = recent.slope * 100
            // "Faster" needs both segments to actually be falling, otherwise a
            // flat stretch followed by noise reads as acceleration.
            trend.isAccelerating = fit.slope < 0 && recent.slope < fit.slope * 1.5
        }
        return trend
    }

    private static func leastSquares(_ points: [(cycle: Int, health: Double)])
        -> (slope: Double, intercept: Double, margin: Double, rSquared: Double)? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + Double($1.cycle) } / n
        let meanY = points.reduce(0) { $0 + $1.health } / n

        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for point in points {
            let dx = Double(point.cycle) - meanX
            let dy = point.health - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        var residuals = 0.0
        for point in points {
            let r = point.health - (intercept + slope * Double(point.cycle))
            residuals += r * r
        }
        let degrees = n - 2
        let standardError = degrees > 0 ? sqrt(residuals / degrees / sxx) : 0
        let rSquared = syy > 0 ? max(0, 1 - residuals / syy) : 0
        return (slope, intercept, tValue(degrees) * standardError, rSquared)
    }

    /// Two-tailed 95 % t for small samples; 1.96 beyond the table.
    private static func tValue(_ degrees: Double) -> Double {
        let table: [Double] = [12.71, 4.30, 3.18, 2.78, 2.57, 2.45, 2.36, 2.31,
                               2.26, 2.23, 2.20, 2.18, 2.16, 2.14, 2.13, 2.12,
                               2.11, 2.10, 2.09, 2.09, 2.08, 2.07, 2.07, 2.06,
                               2.06, 2.06, 2.05, 2.05, 2.05, 2.04]
        let index = Int(degrees.rounded()) - 1
        guard index >= 0 else { return 12.71 }
        return index < table.count ? table[index] : 1.96
    }
}

/// Descriptive least-squares slope; no lifetime extrapolation or probability claim.
struct HealthRegression {
    let changePer30Days: Double
    let rSquared: Double
    let sampleCount: Int
    let spanDays: Double

    static func fit(_ samples: [(Date, Double)]) -> Self? {
        let points = samples.filter { $0.1.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        guard points.count >= 4, let first = points.first, let last = points.last else { return nil }
        let span = last.0.timeIntervalSince(first.0) / 86400
        guard span >= 14, Set(points.map { Calendar.current.startOfDay(for: $0.0) }).count >= 4 else { return nil }
        let xs = points.map { $0.0.timeIntervalSince(first.0) / 86400 }
        let ys = points.map { $0.1 }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let residual = zip(xs, ys).reduce(0) { $0 + pow($1.1 - (my + slope * ($1.0 - mx)), 2) }
        let total = ys.reduce(0) { $0 + pow($1 - my, 2) }
        return Self(changePer30Days: slope * 30, rSquared: total > 0 ? max(0, 1 - residual / total) : 0,
                    sampleCount: points.count, spanDays: span)
    }
}

/// Windowed descriptive comparison, not a prediction of battery lifetime.
struct HealthWindow {
    let days: [DailyStat]
    let records: [CalibrationRecord]
    let excludedRecords: Int

    init(days: [DailyStat], records: [CalibrationRecord], count: Int, now: Date = Date(), calendar: Calendar = .current) {
        let start = calendar.date(byAdding: .day, value: -(max(1, count) - 1), to: calendar.startOfDay(for: now)) ?? now
        self.days = days.filter { $0.day >= start && $0.day <= now && !$0.isEmpty }.sorted { $0.day < $1.day }
        let candidates = records.filter { $0.endDate >= start && $0.endDate <= now }
        self.records = candidates.filter {
            $0.quality?.eligibleForAggregation == true && $0.calculatedCapacityMAh.isFinite && $0.calculatedCapacityMAh > 0
        }.sorted { $0.endDate < $1.endDate }
        excludedRecords = candidates.count - self.records.count
    }

    static func delta(_ values: [Double]) -> Double? {
        let valid = values.filter { $0.isFinite && $0 > 0 }
        guard valid.count >= 2, let first = valid.first, let last = valid.last else { return nil }
        return last - first
    }
    /// Latest eligible measurement anchors comparisons; missing conditions are excluded.
    var comparableRecords: [CalibrationRecord] {
        guard let reference = records.last?.conditions else { return [] }
        return records.filter { $0.conditions.map { reference.matches($0) } == true }
    }
    var capacityDelta: Double? { Self.delta(comparableRecords.map { $0.calculatedCapacityMAh }) }
    var resistanceDelta: Double? { Self.delta(comparableRecords.map { $0.internalResistanceMilliohm }) }
    var capacityRate: HealthRegression? {
        HealthRegression.fit(comparableRecords.map { ($0.endDate, $0.calculatedCapacityMAh) })
    }
    var resistanceRate: HealthRegression? {
        HealthRegression.fit(comparableRecords.map { ($0.endDate, $0.internalResistanceMilliohm) })
    }
    var reportedDelta: Double? { Self.delta(days.compactMap { $0.reportedCapacityMAh.map(Double.init) }) }
    var cycleDelta: Double? {
        let values = days.map { Double($0.cycleCount) }
        guard let result = Self.delta(values), result >= 0 else { return nil }
        return result
    }
    var highTemperatureHours: Double? {
        let values = days.compactMap { $0.highTemperatureSeconds }
        return values.isEmpty ? nil : values.reduce(0, +) / 3600
    }
}

final class DailyHistory: ObservableObject {

    static let shared = DailyHistory()

    @Published private(set) var days: [DailyStat] = []
    /// How the last read went. Set at launch, cleared when the user
    /// acknowledges it. `needsAttention` is what the UI keys off.
    @Published private(set) var readStatus: StoreReadStatus = .clean

    private let calendar = Calendar.current
    private var dirty = false
    private var safeToRotate = false
    private let retentionDays = 400

    private init() {
        load()
    }

    // MARK: - Recording

    func accumulate(chargeWh: Double,
                    dischargeWh: Double,
                    temperature: Double,
                    percentage: Int,
                    plugged: Bool,
                    health: Int,
                    cycleCount: Int,
                    reportedCapacityMAh: Int = 0,
                    seconds: TimeInterval) {
        guard seconds > 0, seconds < 300 else { return }
        let today = calendar.startOfDay(for: Date())

        var stat: DailyStat
        if let last = days.last, calendar.isDate(last.day, inSameDayAs: today) {
            stat = last
            days.removeLast()
        } else {
            stat = DailyStat(day: today, minPercentage: percentage, maxPercentage: percentage)
        }

        stat.chargeWh += max(0, chargeWh)
        stat.dischargeWh += max(0, dischargeWh)
        if temperature > 0, temperature < 120 {
            stat.temperatureSum += temperature
            stat.temperatureSamples += 1
            stat.maxTemperature = max(stat.maxTemperature, temperature)
        }
        stat.minPercentage = min(stat.minPercentage, percentage)
        stat.maxPercentage = max(stat.maxPercentage, percentage)
        if plugged { stat.pluggedSeconds += seconds }
        if health > 0 { stat.lastHealthPercent = health }
        if cycleCount > 0 { stat.cycleCount = cycleCount }
        if reportedCapacityMAh > 0 { stat.reportedCapacityMAh = reportedCapacityMAh }
        if temperature > 0, temperature < 120 {
            stat.observedSeconds = (stat.observedSeconds ?? 0) + seconds
            stat.highTemperatureSeconds = (stat.highTemperatureSeconds ?? 0) + (temperature >= 40 ? seconds : 0)
        }
        // Hour buckets: the profile needs "what does 14:00 usually cost", which
        // a daily total cannot answer.
        let hour = calendar.component(.hour, from: Date())
        var hourWh = stat.hourDischargeWh ?? Array(repeating: 0, count: 24)
        var hourPlugged = stat.hourPluggedSeconds ?? Array(repeating: 0, count: 24)
        var hourSeen = stat.hourObservedSeconds ?? Array(repeating: 0, count: 24)
        hourWh[hour] += max(0, dischargeWh)
        if plugged { hourPlugged[hour] += seconds }
        hourSeen[hour] += seconds
        stat.hourDischargeWh = hourWh
        stat.hourPluggedSeconds = hourPlugged
        stat.hourObservedSeconds = hourSeen

        days.append(stat)
        if days.count > retentionDays { days.removeFirst(days.count - retentionDays) }
        dirty = true
    }

    /// A contiguous run of calendar days ending today, with empty rows filled in
    /// so a week the app was closed shows as a gap rather than a false zero.
    func series(days count: Int) -> [DailyStat] {
        let today = calendar.startOfDay(for: Date())
        var byDay: [Date: DailyStat] = [:]
        for stat in days {
            byDay[calendar.startOfDay(for: stat.day)] = stat
        }
        var result: [DailyStat] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            result.append(byDay[day] ?? DailyStat(day: day, minPercentage: 0, maxPercentage: 0))
        }
        return result
    }

    func clear() {
        days = []
        dirty = false
        // Deleting only the main file would leave the backup behind, and the
        // next start would "recover" the history the user just wiped.
        StoreIO.discard(file: fileURL)
    }

    /// Dismisses the startup banner without touching the quarantined file.
    func acknowledgeReadIssue() {
        readStatus = .clean
    }

    // MARK: - Persistence

    var fileURL: URL {
        CalibrationStore.directory.appendingPathComponent("daily.json")
    }

    func save() {
        guard dirty else { return }
        guard StoreIO.save(days, to: fileURL, rotate: safeToRotate) else { return }
        // After the first successful save the file on disk is known good, so
        // the next save may copy it into the backup slot.
        safeToRotate = true
        dirty = false
    }

    private func load() {
        let read = StoreIO.load(DailyStat.self, from: fileURL)
        days = read.value
        readStatus = read.status
        safeToRotate = read.safeToRotate
    }
}
