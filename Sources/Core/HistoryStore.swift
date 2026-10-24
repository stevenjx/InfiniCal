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
