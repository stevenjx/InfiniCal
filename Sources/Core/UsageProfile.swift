//
//  UsageProfile.swift
//  "At this rate, when will it die?" — answered from the user's own weeks.
//
//  `BatterySnapshot.remainingHours` divides the energy left by the power drawn
//  right now. That number is correct for the next ten minutes and wrong the
//  moment a process exits or the lid closes: one Chrome tab can move it by an
//  hour. The machine has been sampling its own discharge for weeks, so the
//  better answer is "on a Tuesday at 14:00 this Mac usually draws 9 W".
//
//  Everything here is a pure function over `DailyStat` rows. No clock is read
//  inside; `now` comes in. That is what makes the forecast testable, and it is
//  also what keeps the two numbers on the dashboard honest — one is "right now",
//  the other says which days it is assuming.
//

import Foundation

/// What the forecast is based on. The UI prints this, because a prediction
/// without its assumption is a guess wearing a number.
enum UsageForecastBasis: Equatable {
    /// Fewer than `UsageProfile.minimumDays` usable days: fall back to the
    /// instantaneous draw and say so.
    case currentDraw
    /// The user's own history for this weekday and hour.
    case profile(days: Int)
}

struct UsageForecast: Equatable {
    /// nil when even the fallback has nothing to divide by.
    var minutes: Int?
    var basis: UsageForecastBasis
    /// Average draw the walk-forward used at the current hour, watts.
    var watts: Double = 0
    /// Hours the pack is expected to last, from now.
    var date: Date?

    var hours: Double? { minutes.map { Double($0) / 60 } }
}

struct ChargingWindow: Equatable {
    /// Hour of day the window starts, 0…23.
    var startHour: Int
    /// Average draw during those two hours, watts.
    var watts: Double
    var sampleDays: Int
}

enum UsageProfile {

    /// 24 buckets, one per hour of the day. Weekday vs weekend is folded in on
    /// purpose: most people's Tuesday and Saturday differ more than two
    /// neighbouring Tuesdays do, and splitting the sample by weekday left
    /// 14-day histories with almost no per-bucket data.
    struct HourProfile: Equatable {
        /// Average discharge watts per hour of day. nil = not enough samples.
        var watts: [Double?] = Array(repeating: nil, count: 24)
        /// Days that contributed to each hour.
        var days: [Int] = Array(repeating: 0, count: 24)

        var usableHours: Int { watts.compactMap { $0 }.count }
    }

    /// A bucket needs this many observed days before it is allowed to drive the
    /// forecast. One unusual afternoon is not a habit.
    static let minimumBucketDays = 3
    /// The whole forecast needs this many usable days.
    static let minimumDays = 5
    /// Samples are folded over this window, as planned.
    static let windowDays = 14
    /// An hour counts as "on battery" only if the adapter was connected for less
    /// than this share of it.
    static let pluggedShareLimit = 0.5
    /// Guard rails: a bucket below this is noise (the machine was asleep), above
    /// it is a desktop replacement being used as one.
    static let minimumWatts = 0.5
    static let maximumWatts = 80.0
    /// Longer than this is not a prediction, it is a fantasy.
    static let maximumForecastHours = 48.0

    // MARK: - Profile

    static func build(from days: [DailyStat], now: Date = Date(),
                      calendar: Calendar = .current) -> HourProfile {
        let start = now.addingTimeInterval(-Double(windowDays) * 86400)
        var sums = Array(repeating: 0.0, count: 24)
        var counts = Array(repeating: 0, count: 24)

        for day in days where day.day >= start && day.day <= now {
            guard let wh = day.hourDischargeWh, wh.count == 24,
                  let plugged = day.hourPluggedSeconds, plugged.count == 24,
                  let seen = day.hourObservedSeconds, seen.count == 24 else { continue }
            for hour in 0..<24 {
                // An hour with no sampling is not zero consumption; it is an
                // hour the app did not see.
                guard seen[hour] >= 600 else { continue }
                guard plugged[hour] <= seen[hour] * pluggedShareLimit else { continue }
                let watts = wh[hour] / (seen[hour] / 3600)
                guard watts.isFinite, watts >= minimumWatts, watts <= maximumWatts else { continue }
                sums[hour] += watts
                counts[hour] += 1
            }
        }

        var profile = HourProfile()
        for hour in 0..<24 {
            profile.days[hour] = counts[hour]
            if counts[hour] >= minimumBucketDays {
                profile.watts[hour] = sums[hour] / Double(counts[hour])
            }
        }
        return profile
    }

    // MARK: - Forecast

    /// Walks forward hour by hour through the profile until the stored energy
    /// runs out. That is deliberately *not* `energy / average power`: what
    /// matters is which hours are coming next, not the day's mean.
    ///
    /// `remainingWh` and `currentWatts` come from the pack itself, so a
    /// brand-new machine still answers "about N hours" instead of refusing.
    static func forecast(profile: HourProfile, remainingWh: Double, currentWatts: Double,
                         now: Date = Date(), calendar: Calendar = .current) -> UsageForecast {
        let usableDays = Set((0..<24).filter { profile.watts[$0] != nil }).count
        let basisDays = profile.days.max() ?? 0
        let useProfile = usableDays >= minimumDays && basisDays >= minimumDays

        guard remainingWh > 0 else {
            return UsageForecast(minutes: nil, basis: useProfile ? .profile(days: basisDays) : .currentDraw)
        }

        // Fallback: linear extrapolation at the instantaneous draw. Below the
        // measurement floor there is no honest number to publish.
        guard useProfile else {
            guard currentWatts >= minimumWatts else {
                return UsageForecast(minutes: nil, basis: .currentDraw, watts: currentWatts)
            }
            let hours = min(maximumForecastHours, remainingWh / currentWatts)
            let minutes = Int((hours * 60).rounded())
            return UsageForecast(minutes: minutes, basis: .currentDraw, watts: currentWatts,
                                 date: now.addingTimeInterval(hours * 3600))
        }

        var energy = remainingWh
        var cursor = now
        var wattsAtNow = profile.watts[calendar.component(.hour, from: now)] ?? currentWatts
        var elapsed: TimeInterval = 0
        // 15-minute steps: an hour bucket is a coarse model, and a step that
        // matches it would quantise the answer to whole hours.
        let step: TimeInterval = 900

        while elapsed < maximumForecastHours * 3600 {
            let hour = calendar.component(.hour, from: cursor)
            let watts = profile.watts[hour] ?? max(minimumWatts, currentWatts)
            wattsAtNow = profile.watts[calendar.component(.hour, from: now)] ?? watts
            energy -= watts * step / 3600
            if energy <= 0 {
                let minutes = max(1, Int((elapsed / 60).rounded()))
                return UsageForecast(minutes: minutes, basis: .profile(days: basisDays),
                                     watts: wattsAtNow, date: cursor)
            }
            cursor = cursor.addingTimeInterval(step)
            elapsed += step
        }
        // Survives 48 h of the profile: say "> 48 h" rather than inventing a
        // precise number past the model's reach.
        return UsageForecast(minutes: nil, basis: .profile(days: basisDays), watts: wattsAtNow)
    }

    // MARK: - Charging window

    /// The two consecutive hours with the lowest expected draw, i.e. when the
    /// machine is idlest. Suggesting this is the one piece of advice the profile
    /// can give that the user cannot read off a chart.
    static func bestChargingWindow(profile: HourProfile) -> ChargingWindow? {
        let usable = (0..<24).filter { profile.watts[$0] != nil }
        guard usable.count >= 12 else { return nil }
        var best: ChargingWindow?
        for start in 0..<24 {
            let next = (start + 1) % 24
            guard let first = profile.watts[start], let second = profile.watts[next] else { continue }
            let average = (first + second) / 2
            let days = min(profile.days[start], profile.days[next])
            if best == nil || average < (best?.watts ?? .infinity) {
                best = ChargingWindow(startHour: start, watts: average, sampleDays: days)
            }
        }
        return best
    }
}