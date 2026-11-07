//
//  StorageMode.swift
//  "This Mac is going in a drawer for six months."
//
//  A pack stored at 100 % loses capacity faster than one stored near 55 %, and a
//  pack stored empty can go into deep discharge and never come back. The app
//  already has the two levers this needs — discharge to a target, then hold —
//  so this file is the *policy*: which percentage, when to remind, and what to
//  say afterwards.
//
//  Pure values and a pure reminder rule; the button lives in the charge page.
//

import Foundation

enum StorageMode {

    /// The long-term storage charge level recommended for lithium packs: low
    /// enough to slow calendar ageing, high enough to avoid deep discharge.
    static let targetPercentage = 55
    /// Below this the pack risks self-discharge into the unsafe range.
    static let minimumSafePercentage = 20
    /// Recharge interval while in storage, from the same recommendation.
    static let reminderDays = 90

    /// Should the app suggest topping the pack back up? Only while the pack is
    /// actually in storage, and only after the interval.
    static func needsTopUp(startedAt: Date?, now: Date = Date()) -> Bool {
        guard let startedAt else { return false }
        let days = now.timeIntervalSince(startedAt) / 86400
        return days >= Double(reminderDays)
    }

    /// Days since storage started, for the UI and the advice text.
    static func daysStored(startedAt: Date?, now: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int((now.timeIntervalSince(startedAt) / 86400).rounded(.down)))
    }

    /// A pack already below the safe floor should be charged, not discharged.
    /// Returns the message to show instead of starting a discharge.
    static func refusal(percentage: Int) -> String? {
        if percentage <= targetPercentage {
            return tf("当前电量 {p}% 已不高于存放目标 {p}%，无需放电。", "\(percentage)", "\(targetPercentage)")
        }
        return nil
    }

    /// Leaving storage: say what to do with the pack next, not just "done".
    static func exitGuidance(percentage: Int) -> String {
        if percentage < minimumSafePercentage {
            return tf("电量已低至 {p}%。长期不用请先充到 {p}% 再收纳，低于 {p}% 存放会加速老化且有深度放电风险。",
                      "\(percentage)", "\(targetPercentage)", "\(minimumSafePercentage)")
        }
        return tf("已退出存放模式，当前 {p}%。若继续长期不用，建议每 {p} 天补电到 {p}%。",
                  "\(percentage)", "\(reminderDays)", "\(targetPercentage)")
    }
}