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

final class DailyHistory: ObservableObject {

    static let shared = DailyHistory()

    @Published private(set) var days: [DailyStat] = []

    private let calendar = Calendar.current
    private var dirty = false
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
        dirty = true
        save()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        CalibrationStore.directory.appendingPathComponent("daily.json")
    }

    func save() {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(days) else { return }
        guard (try? data.write(to: fileURL, options: [.atomic])) != nil else { return }
        dirty = false
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        days = (try? decoder.decode([DailyStat].self, from: data)) ?? []
    }
}
