//
//  Notifier.swift
//  Event notifications.
//
//  The charge loop runs every two seconds, so the same physical event (battery
//  reached its limit, temperature crossed the cap) would otherwise produce a
//  banner on every tick. Each event has a key and a cooldown; the first one wins
//  and the rest are dropped.
//

import Foundation
import UserNotifications

final class Notifier {

    static let shared = Notifier()

    private var lastPosted: [String: Date] = [:]
    private var didRequestAuthorization = false

    private init() {}

    /// Requested targets and independent telemetry stay explicitly separated.
    static func evidenceBody(_ body: String, requested: String, actual: String, sampledAt: Date) -> String {
        body + "\n" + tf("请求值：{p}", requested) + "\n" + tf("实际观测：{p}", actual)
            + "\n" + tf("采样时间：{p}", sampledAt.formatted(date: .omitted, time: .standard))
    }

    /// Asked once, on the first launch that needs it.
    func prepare() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(key: String,
              title: String,
              body: String,
              cooldown: TimeInterval = 300,
              sound: Bool = true) {
        let now = Date()
        if let last = lastPosted[key], now.timeIntervalSince(last) < cooldown { return }
        lastPosted[key] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(key)-\(UUID().uuidString)",
                                  content: content,
                                  trigger: nil))
    }
}
