//
//  DeviceProfile.swift
//  Cross-model capability profile and the offline rule library behind it.
//
//  Everything in this file is pure: a profile is a value, a rule is a value, and
//  the assessment is a function of the two. Hardware probing and disk storage
//  live in `DeviceProfileStore.swift`, so this file compiles and tests on its
//  own without SMC, a helper or a battery.
//
//  Privacy: a profile holds a public model code (`Mac14,9`), a chip brand
//  string and an OS version. No serial number, user name, host name or path is
//  ever collected, and nothing here uploads anything.
//

import Foundation

enum ChipFamily: String, Codable, CaseIterable {
    case appleSilicon = "apple-silicon"
    case intel
    case unknown

    var title: String {
        switch self {
        case .appleSilicon: return t("Apple Silicon")
        case .intel: return t("Intel")
        case .unknown: return t("未知")
        }
    }

    /// Classification from the public brand string only.
    static func classify(_ brand: String) -> ChipFamily {
        if brand.hasPrefix("Apple ") { return .appleSilicon }
        if brand.contains("Intel") { return .intel }
        return .unknown
    }
}

/// What this machine actually exposes. Capabilities are facts measured at
/// runtime; the rule library only adds knowledge runtime cannot observe.
struct DeviceProfile: Codable, Equatable {
    /// `hw.model`, a public model code such as `Mac14,9`.
    var model: String = "--"
    /// `machdep.cpu.brand_string`, e.g. `Apple M2 Pro`.
    var chip: String = "--"
    var family: ChipFamily = .unknown
    var macOSMajor: Int = 0
    /// Mirrors `ChargeStrategy.rawValue`; kept as a string so the rules stay
    /// readable in JSON and do not depend on the enum's declaration order.
    var chargeStrategy: String = "unavailable"
    var helperAvailable: Bool = false
    var fanCount: Int = 0
    var hasBattery: Bool = false
    /// Temperature keys that answered with a plausible reading.
    var sensorKeys: [String] = []

    var summary: String {
        "\(model) · \(chip) · macOS \(macOSMajor)"
    }
}

/// One entry of the offline knowledge base.
///
/// Every constraint is optional, and an empty list means "any". A rule that
/// matches contributes its limitations and recommendations; a more specific
/// rule is listed first so model-specific knowledge outranks generic advice.
struct CapabilityRule: Codable, Equatable, Identifiable {
    var id: String
    /// Case-insensitive prefixes, e.g. `MacBookAir` or `Mac14,`.
    var modelPrefixes: [String] = []
    var families: [ChipFamily] = []
    var minMacOSMajor: Int?
    var maxMacOSMajor: Int?
    /// `ChargeStrategy.rawValue` values this rule applies to.
    var strategies: [String] = []
    var limitations: [String] = []
    var recommendations: [String] = []
    var priority: Int = 0
    /// Where the claim comes from. Shown in the UI so a rule is never taken on
    /// faith, and so an unverified rule is visibly unverified.
    var source: String = ""

    var specificity: Int {
        var score = 0
        if !modelPrefixes.isEmpty { score += 4 }
        if !families.isEmpty { score += 1 }
        if minMacOSMajor != nil || maxMacOSMajor != nil { score += 2 }
        if !strategies.isEmpty { score += 1 }
        return score
    }

    func matches(_ profile: DeviceProfile) -> Bool {
        if !modelPrefixes.isEmpty {
            let model = profile.model.lowercased()
            guard modelPrefixes.contains(where: { !$0.isEmpty && model.hasPrefix($0.lowercased()) })
            else { return false }
        }
        if !families.isEmpty, !families.contains(profile.family) { return false }
        if let min = minMacOSMajor, profile.macOSMajor < min { return false }
        if let max = maxMacOSMajor, profile.macOSMajor > max { return false }
        if !strategies.isEmpty, !strategies.contains(profile.chargeStrategy) { return false }
        return true
    }
}

/// A versioned, replaceable set of rules. The version is what makes a bad
/// update reversible: the store keeps the previous library and can restore it.
struct CapabilityRuleLibrary: Codable, Equatable {
    var version: Int
    /// Informational only; never used for matching.
    var updated: String
    var rules: [CapabilityRule]

    /// Nil when the library is usable, otherwise the reason it is not.
    var validationError: String? {
        if version <= 0 { return t("规则库版本号必须大于 0") }
        if rules.isEmpty { return t("规则库不能为空") }
        var seen = Set<String>()
        for rule in rules {
            let id = rule.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return t("存在没有 id 的规则") }
            if !seen.insert(id).inserted { return tf("规则 id 重复：{p}", id) }
            if rule.limitations.isEmpty && rule.recommendations.isEmpty {
                return tf("规则 {p} 既没有已知限制也没有推荐策略", id)
            }
        }
        return nil
    }

    static let bundled = CapabilityRuleLibrary(
        version: 1,
        updated: "2026-11-04",
        rules: [
            CapabilityRule(
                id: "system-limit-floor-80",
                minMacOSMajor: 26,
                strategies: ["systemLimit"],
                limitations: [
                    "系统充电上限（MCL）最低只能设为 80%，无法表达更低的限制。",
                ],
                recommendations: [
                    "需要低于 80% 的上限时，用充放电循环维持区间，而不是改写上限。",
                ],
                priority: 20,
                source: "SystemChargeLimit.minimumSupported"),
            CapabilityRule(
                id: "system-limit-preferred",
                minMacOSMajor: 26,
                strategies: ["systemLimit"],
                recommendations: [
                    "优先使用系统充电上限：它由 powerd 持久执行，重启后仍然有效。",
                    "macOS 26 之后 SMC 控制键通常已被移除，不要把 BCLM 当作后备方案。",
                ],
                priority: 10,
                source: "Mac14,9 / macOS 27 实测：BCLM、CH0B、CH0C、CHTE 均返回 keyNotFound"),
            CapabilityRule(
                id: "bclm-readback",
                strategies: ["bclm"],
                limitations: [
                    "BCLM 写入可能被 macOS 或固件重写，写入成功不等于持续生效。",
                ],
                recommendations: [
                    "依赖定期回读校验；回读值与目标不一致时应重新写入并提示。",
                ],
                priority: 10,
                source: "ChargeController.applyChargeLimit 的回读校验"),
            CapabilityRule(
                id: "intel-no-socpower",
                families: [.intel],
                limitations: [
                    "Intel 机型没有 SoC 功耗传感器，进程功耗归因与 CPU/GPU 分项不可用。",
                ],
                recommendations: [
                    "功耗与续航按整机功率解释；进程排行只展示 CPU 占比，不折算瓦数。",
                ],
                priority: 10,
                source: "SoC 功耗来自 powermetrics，仅 Apple Silicon 有对应分项"),
            CapabilityRule(
                id: "intel-inflow-lease",
                families: [.intel],
                limitations: [
                    "DisableInflow 是 15 秒租约，停止刷新后充电会自行恢复。",
                ],
                recommendations: [
                    "放电任务需要持续心跳，任务期间不要休眠或退出应用。",
                ],
                priority: 10,
                source: "诊断中心：Intel / lease 15 s"),
            CapabilityRule(
                id: "apple-silicon-temperature-keys",
                families: [.appleSilicon],
                limitations: [
                    "Apple Silicon 的温度键与 Intel 不同（Tp01、Tg0B 等），部分键只读或不存在。",
                ],
                recommendations: [
                    "温控曲线只使用实测可读的键，不按机型硬编码键名。",
                ],
                priority: 5,
                source: "诊断中心的只读传感器探测"),
            CapabilityRule(
                id: "desktop-no-battery",
                modelPrefixes: ["Macmini", "MacStudio", "MacPro", "iMac"],
                limitations: [
                    "台式机型没有电池，充电控制、校准与电池健康不适用。",
                ],
                recommendations: [
                    "只使用风扇、睡眠与功耗相关功能。",
                ],
                priority: 10,
                source: "机型类别"),
            CapabilityRule(
                id: "fanless-air",
                modelPrefixes: ["MacBookAir10,1", "Mac14,2", "Mac15,12", "Mac15,13"],
                limitations: [
                    "该机型为无风扇设计，没有可控制的风扇。",
                ],
                recommendations: [
                    "忽略风扇面板与曲线设置，散热只能依靠系统降频。",
                ],
                priority: 10,
                source: "机型规格：Apple Silicon MacBook Air 无风扇"),
        ])
}

/// The library plus the version it replaced, so an update can be undone.
struct CapabilityRuleArchive: Codable, Equatable {
    var current: CapabilityRuleLibrary
    var previous: CapabilityRuleLibrary?

    static let bundled = CapabilityRuleArchive(current: .bundled, previous: nil)

    func installing(_ library: CapabilityRuleLibrary) -> CapabilityRuleArchive {
        guard library != current else { return self }
        return CapabilityRuleArchive(current: library, previous: current)
    }

    /// Swaps current and previous, so pressing rollback twice returns to where
    /// it started. Nil when there is nothing to restore.
    func rollingBack() -> CapabilityRuleArchive? {
        guard let previous else { return nil }
        return CapabilityRuleArchive(current: previous, previous: current)
    }
}

/// The result of applying the library to one profile. `notes` are runtime
/// observations, kept separate from rule text so the two are never confused.
struct CapabilityAssessment: Codable, Equatable {
    var profile: DeviceProfile
    var libraryVersion: Int
    var ruleIDs: [String] = []
    var limitations: [String] = []
    var recommendations: [String] = []
    var notes: [String] = []
}

extension CapabilityRuleLibrary {

    func assess(_ profile: DeviceProfile) -> CapabilityAssessment {
        let matched = rules
            .filter { $0.matches(profile) }
            .sorted { lhs, rhs in
                if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.id < rhs.id
            }
        var limitations: [String] = []
        var recommendations: [String] = []
        for rule in matched {
            for item in rule.limitations where !limitations.contains(item) { limitations.append(item) }
            for item in rule.recommendations where !recommendations.contains(item) { recommendations.append(item) }
        }
        return CapabilityAssessment(profile: profile, libraryVersion: version,
                                    ruleIDs: matched.map(\.id),
                                    limitations: limitations,
                                    recommendations: recommendations,
                                    notes: Self.runtimeNotes(profile))
    }

    /// Facts the profile measured. These are not rules: they describe this
    /// machine now, and disappear as soon as the fact does.
    static func runtimeNotes(_ profile: DeviceProfile) -> [String] {
        var notes: [String] = []
        if !profile.hasBattery {
            notes.append(t("未检测到电池：充电控制、校准与电池健康不适用。"))
        }
        if profile.fanCount == 0 {
            notes.append(t("未检测到风扇：风扇控制不适用。"))
        }
        if !profile.helperAvailable {
            notes.append(t("特权助手未连接：SMC 写入与 SoC 功耗测量不可用。"))
        } else if profile.chargeStrategy == "unavailable" {
            notes.append(t("助手已连接，但没有找到可写的充电控制键。"))
        }
        if profile.hasBattery && profile.sensorKeys.isEmpty {
            notes.append(t("没有读到温度传感器：温控与热保护无法生效。"))
        }
        return notes
    }
}
