import Foundation

/// Which rule currently owns the charge hardware.
///
/// This enum is the single written-down copy of the P0-03 safety order. The
/// control loop no longer relies on the order of its `if` statements: it asks
/// the arbiter who wins and only the winner's branch is allowed to act.
///
/// Scheduled tasks are deliberately absent. They never touch the hardware on
/// their own — they call the same levers (`topUp`, `pauseCharging`,
/// `startDischarge`) — and their conflicts with each other are decided by
/// `TaskPolicy` and written to the task history.
enum ChargeAuthority: Int, CaseIterable {
    /// The adapter state is unknown, so nothing else may decide yet.
    case emergency = 0
    /// A calibration session drives the ceiling itself.
    case calibration = 1
    /// The user paused charging by hand.
    case manualPause = 2
    /// Discharging on purpose, either to a manual target or down to the limit.
    case autoDischarge = 3
    /// Battery temperature above the configured ceiling.
    case heatProtect = 4
    /// Holding between the sailing floor and the limit.
    case sailing = 5
    /// The ordinary ceiling is reached.
    case chargeLimit = 6

    var title: String {
        switch self {
        case .emergency: return t("紧急保护")
        case .calibration: return t("校准")
        case .manualPause: return t("手动暂停")
        case .autoDischarge: return t("放电")
        case .heatProtect: return t("过热保护")
        case .sailing: return t("航海模式")
        case .chargeLimit: return t("充电上限")
        }
    }
}

/// One strategy asking for the hardware right now, with the reason it is
/// asking. The reason is what makes a conflict record useful later: "过热保护"
/// alone does not say which temperature triggered it.
struct ChargeClaim: Equatable {
    var strategy: ChargeAuthority
    var reason: String
}

/// The result of one arbitration: who acts, and who is standing down.
struct ChargeArbitration: Equatable {
    var winner: ChargeClaim
    var suppressed: [ChargeClaim]

    var isConflict: Bool { !suppressed.isEmpty }

    var suppressedTitles: String {
        suppressed.map { $0.strategy.title }.joined(separator: "、")
    }
}

/// Everything the arbitration needs, as plain values.
///
/// Keeping it a value type is what makes the priority testable without a
/// battery: the same inputs that produce a conflict on real hardware produce
/// the same record in the quality gate.
struct ChargeArbitrationInput: Equatable {
    var percentage: Int = 0
    var limit: Int = 80
    var temperature: Double = 0
    var heatProtectMode: Bool = false
    var maxTemperature: Int = 35
    /// The over-temperature latch: stays on until the pack cools by 2 °C.
    var heatPause: Bool = false
    var userPaused: Bool = false
    var manualDischargeTarget: Int?
    var automaticDischarge: Bool = false
    var sailingMode: Bool = false
    var sailingLevel: Int = 5
    var pluggedIn: Bool = false
    var calibrationRunning: Bool = false
    var adapterRestoreFailed: Bool = false
    var previousChargingAllowed: Bool?
    var isCharging: Bool = false
}

enum ChargeArbiter {

    /// Lowest rank wins; ties cannot happen because a strategy claims once.
    static func arbitrate(_ claims: [ChargeClaim]) -> ChargeArbitration? {
        var seen = Set<ChargeAuthority>()
        var ordered: [ChargeClaim] = []
        for claim in claims.sorted(by: { $0.strategy.rawValue < $1.strategy.rawValue }) {
            guard seen.insert(claim.strategy).inserted else { continue }
            ordered.append(claim)
        }
        guard let winner = ordered.first else { return nil }
        return ChargeArbitration(winner: winner, suppressed: Array(ordered.dropFirst()))
    }

    /// Which strategies are active for this state. Pure: no hardware, no time.
    static func claims(for input: ChargeArbitrationInput) -> [ChargeClaim] {
        var claims: [ChargeClaim] = []

        if input.adapterRestoreFailed {
            claims.append(ChargeClaim(strategy: .emergency,
                                      reason: t("适配器状态不确定，先恢复供电")))
        }
        if input.calibrationRunning {
            claims.append(ChargeClaim(strategy: .calibration,
                                      reason: t("校准会话占用充电控制")))
        }
        if input.userPaused {
            claims.append(ChargeClaim(strategy: .manualPause,
                                      reason: t("手动暂停充电")))
        }
        if let target = input.manualDischargeTarget {
            claims.append(ChargeClaim(strategy: .autoDischarge,
                                      reason: tf("放电至 {p}%", "\(target)")))
        } else if input.automaticDischarge, input.percentage > input.limit {
            claims.append(ChargeClaim(strategy: .autoDischarge,
                                      reason: tf("电量高于上限 {p}%", "\(input.limit)")))
        }
        if input.heatProtectMode,
           input.temperature >= Double(input.maxTemperature) || input.heatPause {
            claims.append(ChargeClaim(strategy: .heatProtect,
                                      reason: String(format: t("电池温度 %.1f°C，上限 %d°C"),
                                                     input.temperature, input.maxTemperature)))
        }

        let chargingAllowed = ChargePolicy.allowsCharging(
            percentage: input.percentage, limit: input.limit, sailing: input.sailingMode,
            difference: input.sailingLevel, previous: input.previousChargingAllowed,
            isCharging: input.isCharging)

        if input.percentage >= input.limit {
            claims.append(ChargeClaim(strategy: .chargeLimit,
                                      reason: tf("已到上限 {p}%", "\(input.limit)")))
        } else if input.sailingMode, !chargingAllowed {
            let floor = max(1, input.limit - max(1, min(30, input.sailingLevel)))
            claims.append(ChargeClaim(strategy: .sailing,
                                      reason: tf("航海区间保持 {p}%–{p}%", "\(floor)", "\(input.limit)")))
        }

        return claims
    }
}
