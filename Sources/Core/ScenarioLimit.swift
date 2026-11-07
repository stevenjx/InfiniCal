//
//  ScenarioLimit.swift
//  A ceiling that depends on what the machine is doing, not only on a slider.
//
//  The charge limit is one number the user picks once. In practice the right
//  number changes: a Mac docked to a monitor with a 96 W adapter is best held
//  near 55 % for weeks, and the same Mac on a plane the next morning wants 100 %.
//  Rewriting the slider every time is exactly the kind of chore software should
//  absorb — but only if the rewrite is explainable, which is why every scenario
//  here carries the evidence that made it fire.
//
//  Pure values and a pure resolver. The hardware, the clock and the display list
//  are injected by the caller.
//

import Foundation

enum ScenarioKind: String, CaseIterable, Identifiable {
    /// Docked and plugged: the pack sits on the adapter for days.
    case desktop
    /// Big adapter, low pack: the user is about to need the capacity.
    case boost
    /// Overnight window.
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return t("桌面模式")
        case .boost: return t("满血模式")
        case .night: return t("夜间窗口")
        }
    }

    var detail: String {
        switch self {
        case .desktop: return t("接外接屏且插电时，把上限降到 55%：长期插电最省电池")
        case .boost: return t("适配器 ≥ 90 W 且电量 < 40% 时，临时放到 100%")
        case .night: return t("23:00–07:00 之间把上限设为 80%")
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "display"
        case .boost: return "bolt.fill"
        case .night: return "moon.stars"
        }
    }

    /// The ceiling this scenario asks for.
    var limit: Int {
        switch self {
        case .desktop: return 55
        case .boost: return 100
        case .night: return 80
        }
    }
}

/// Which scenarios the user turned on.
struct ScenarioSettings: Equatable {
    var desktop = false
    var boost = false
    var night = false

    func isOn(_ kind: ScenarioKind) -> Bool {
        switch kind {
        case .desktop: return desktop
        case .boost: return boost
        case .night: return night
        }
    }

    mutating func set(_ kind: ScenarioKind, _ value: Bool) {
        switch kind {
        case .desktop: desktop = value
        case .boost: boost = value
        case .night: night = value
        }
    }

    var anyEnabled: Bool { desktop || boost || night }
}

/// Everything a scenario needs, as plain values.
struct ScenarioInput: Equatable {
    var settings = ScenarioSettings()
    var pluggedIn = false
    /// Rated adapter wattage (`AdapterDetails.Watts`), 0 when unknown.
    var adapterWatts = 0
    /// Displays that are not the built-in panel.
    var externalDisplays = 0
    var percentage = 0
    /// Hour of day, 0…23.
    var hour = 0
    /// The user's own ceiling, which a scenario may lower or (for boost) raise.
    var userLimit = 80
}

struct ScenarioResolution: Equatable {
    var kind: ScenarioKind
    var limit: Int
    /// Why it fired, in the user's language. Shown in the charge page and
    /// written to the journal — a silent rewrite of the ceiling is not allowed.
    var evidence: String
}

enum ScenarioLimit {

    /// The window is expressed as a half-open hour range that may wrap past
    /// midnight: 23…7 means 23, 0, 1, …, 6.
    static let nightStart = 23
    static let nightEnd = 7

    /// Priority when several match.
    ///
    /// `boost` wins because it exists for the moment the user is short of
    /// capacity; a low ceiling imposed by the dock must not block it. `desktop`
    /// outranks `night` because a docked machine is a stronger signal than the
    /// clock is.
    static let priority: [ScenarioKind] = [.boost, .desktop, .night]

    static func isNight(hour: Int) -> Bool {
        nightStart > nightEnd
            ? (hour >= nightStart || hour < nightEnd)
            : (hour >= nightStart && hour < nightEnd)
    }

    /// Every scenario that matches right now, best first.
    static func matches(_ input: ScenarioInput) -> [(kind: ScenarioKind, evidence: String)] {
        guard input.pluggedIn, input.settings.anyEnabled else { return [] }
        var hits: [(ScenarioKind, String)] = []

        if input.settings.boost, input.adapterWatts >= 90, input.percentage < 40 {
            hits.append((.boost, tf("适配器 {p} W，电量 {p}%", "\(input.adapterWatts)", "\(input.percentage)")))
        }
        if input.settings.desktop, input.externalDisplays >= 1 {
            hits.append((.desktop, tf("外接屏 {p} 台，适配器 {p} W",
                                      "\(input.externalDisplays)", "\(input.adapterWatts)")))
        }
        if input.settings.night, isNight(hour: input.hour) {
            hits.append((.night, tf("{p}:00–{p}:00 之间", "\(nightStart)", "\(nightEnd)")))
        }
        return hits.sorted { lhs, rhs in
            let l = priority.firstIndex(of: lhs.0) ?? 99
            let r = priority.firstIndex(of: rhs.0) ?? 99
            return l < r
        }
    }

    /// The effective ceiling and why.
    ///
    /// Lowering below the user's own limit is safe and needs no permission.
    /// Raising above it is only allowed for `boost`, which is the one scenario
    /// whose whole purpose is a temporary higher ceiling.
    static func resolve(_ input: ScenarioInput) -> ScenarioResolution? {
        guard let first = matches(input).first else { return nil }
        let requested = first.kind.limit
        let limit = first.kind == .boost ? requested : min(requested, max(1, input.userLimit))
        return ScenarioResolution(kind: first.kind, limit: limit, evidence: first.1)
    }
}