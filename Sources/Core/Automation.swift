//
//  Automation.swift
//  `infinical://` — the scriptable entry point.
//
//  Every control the app already has is reachable from the window. That is
//  fine for a person and useless for a script: Shortcuts, Raycast, Stream Deck
//  and a shell one-liner all need something they can call. A URL scheme is the
//  cheapest such interface — LaunchServices already delivers it, running or
//  not, and the receiving side is a few dozen lines.
//
//  The split here is deliberate: `AutomationURL.parse` is a pure function over
//  a URL, so the accepted grammar and every rejection are covered by the
//  quality gate without touching hardware. `AutomationCenter` is the thin
//  executor that hands a parsed command to `AppState`, which keeps the actual
//  levers (arbiter, journal, manual-override rule) as the single owner.
//

import Foundation

// MARK: - Command

/// A validated automation request.
///
/// Percentages are already range-checked here. `topUp` and `discharge` carry a
/// target because the window's buttons have one; the URL without an argument
/// falls back to the same defaults the buttons use.
enum AutomationCommand: Equatable {
    case limit(Int)
    case pause
    case resume
    case topUp(Int)
    case discharge(Int)
    case calibrate(CalibrationPreset)
    case status

    /// Stable token used in the control journal and in the reply file.
    var name: String {
        switch self {
        case .limit: return "limit"
        case .pause: return "pause"
        case .resume: return "resume"
        case .topUp: return "topup"
        case .discharge: return "discharge"
        case .calibrate: return "calibrate"
        case .status: return "status"
        }
    }

    /// What the command asked for, in the form the journal records as `target`.
    var target: String? {
        switch self {
        case .limit(let value), .topUp(let value), .discharge(let value): return "\(value)%"
        case .calibrate(let preset): return preset.rawValue
        case .pause, .resume, .status: return nil
        }
    }
}

/// Every way a URL can be refused. Each case names the accepted form, because
/// the message is all a script author gets to see.
enum AutomationFailure: Error, Equatable {
    case wrongScheme(String?)
    case unknownAction(String)
    case missingValue(String)
    case malformedValue(String)
    case outOfRange(Int, ClosedRange<Int>)
    case unknownPreset(String)

    var message: String {
        switch self {
        case .wrongScheme(let value):
            return tf("只接受 {p} 开头的链接（收到 {p}）", "infinical://", value ?? "—")
        case .unknownAction(let value):
            return tf("未知动作「{p}」；可用：limit / pause / resume / topup / discharge / calibrate / status", value)
        case .missingValue(let action):
            return tf("{p} 需要一个数值，例如 infinical://{p}/60", action, action)
        case .malformedValue(let value):
            return tf("参数不是整数：{p}", value)
        case .outOfRange(let value, let range):
            return tf("参数 {p} 超出范围 {p}…{p}", "\(value)", "\(range.lowerBound)", "\(range.upperBound)")
        case .unknownPreset(let value):
            return tf("未知校准预设「{p}」；可用：quick / standard / deep", value)
        }
    }
}

// MARK: - Parser

enum AutomationURL {

    static let scheme = "infinical"

    /// Cross-process hand-over channel. A URL opened while the app is already
    /// running usually arrives as an Apple Event, but `open` can start a second
    /// copy that exits on the single-instance guard — that copy forwards the
    /// URL here instead of dropping it.
    static let notificationName = "com.infinitycomputer.infinical.automation"

    /// The floor every charge backend supports. Asking for less would be
    /// silently rounded up by the hardware, so it is refused instead.
    static let percentRange = 5...100

    /// Defaults matching the window's own buttons.
    static let defaultTopUp = 100
    static let defaultDischarge = 50

    static func parse(_ url: URL) -> Result<AutomationCommand, AutomationFailure> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.wrongScheme(url.scheme))
        }
        var action = (url.host ?? "").lowercased()
        var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        // `infinical:///limit/60` (three slashes) has no host, only a path. It
        // means the same thing, so it is accepted instead of silently failing.
        if action.isEmpty, let first = parts.first {
            action = first.lowercased()
            parts.removeFirst()
        }
        let raw = parts.first

        switch action {
        case "limit":
            return percent(raw, action: action).map { .limit($0) }
        case "topup", "top-up":
            guard let raw else { return .success(.topUp(defaultTopUp)) }
            return percent(raw, action: action).map { .topUp($0) }
        case "discharge":
            guard let raw else { return .success(.discharge(defaultDischarge)) }
            return percent(raw, action: action).map { .discharge($0) }
        case "pause":
            return .success(.pause)
        case "resume":
            return .success(.resume)
        case "calibrate":
            guard let raw else { return .failure(.missingValue("calibrate")) }
            let key = raw.lowercased()
            let presets: [(String, CalibrationPreset)] = [
                ("quick", .quickCheck), ("quickcheck", .quickCheck), ("quick-check", .quickCheck),
                ("standard", .standard), ("deep", .deep)
            ]
            guard let preset = presets.first(where: { $0.0 == key })?.1 else {
                return .failure(.unknownPreset(raw))
            }
            return .success(.calibrate(preset))
        case "status":
            return .success(.status)
        case "":
            return .failure(.unknownAction("（空）"))
        default:
            return .failure(.unknownAction(action))
        }
    }

    private static func percent(_ raw: String?, action: String)
        -> Result<Int, AutomationFailure> {
        guard let raw else { return .failure(.missingValue(action)) }
        guard let value = Int(raw) else { return .failure(.malformedValue(raw)) }
        guard percentRange.contains(value) else {
            return .failure(.outOfRange(value, percentRange))
        }
        return .success(value)
    }

    /// Round-trip used by the documentation examples and by the tests, so a
    /// documented URL is the same one the parser accepts.
    static func url(for command: AutomationCommand) -> URL {
        switch command {
        case .limit(let value): return URL(string: "\(scheme)://limit/\(value)")!
        case .topUp(let value): return URL(string: "\(scheme)://topup/\(value)")!
        case .discharge(let value): return URL(string: "\(scheme)://discharge/\(value)")!
        case .calibrate(let preset): return URL(string: "\(scheme)://calibrate/\(preset.rawValue)")!
        case .pause: return URL(string: "\(scheme)://pause")!
        case .resume: return URL(string: "\(scheme)://resume")!
        case .status: return URL(string: "\(scheme)://status")!
        }
    }
}

// MARK: - Executor

/// Hands parsed commands to `AppState` and records the outcome.
///
/// Nothing here touches hardware: `AppState` owns the arbiter, the journal and
/// the manual-override rule, and an automation request has to be subject to all
/// three. This object only adds the parts that are specific to being called
/// from outside — a queue for cold starts, a reply file for `status`, and a
/// message that ends up in `statusNote`.
final class AutomationCenter {

    static let shared = AutomationCenter()

    /// A cold start delivers the URL before `didFinishLaunching` has built the
    /// timers; without this queue the first command of a fresh login is lost.
    private var pending: [URL] = []
    private var ready = false

    private init() {}

    func markReady() {
        ready = true
        let queued = pending
        pending.removeAll()
        for url in queued { handle(url) }
    }

    /// Entry point for both arrival paths (Apple Event and forwarded note).
    /// Always hops to main: the Apple Event arrives on the main run loop, the
    /// forwarded note does not necessarily, and the state object is main-only.
    func handle(_ url: URL) {
        if Thread.isMainThread {
            process(url)
        } else {
            DispatchQueue.main.async { [weak self] in self?.process(url) }
        }
    }

    private func process(_ url: URL) {
        guard ready else {
            pending.append(url)
            return
        }
        switch AutomationURL.parse(url) {
        case .failure(let failure):
            fail(failure, url: url)
        case .success(let command):
            run(command, url: url)
        }
    }

    private func run(_ command: AutomationCommand, url: URL) {
        guard command != .status else { return writeStatus() }
        let state = AppState.shared
        let outcome = state.perform(command)
        ControlJournal.shared.record(ControlEvidence(
            operation: "automation:" + command.name,
            backend: "url-scheme",
            phase: outcome.ok ? .accepted : .failed,
            target: command.target,
            observed: "SOC=\(state.snapshot.percentage)%",
            detail: outcome.message + " · " + url.absoluteString
        ))
        state.statusNote = outcome.message
        state.lastMessage = outcome.message
    }

    private func fail(_ failure: AutomationFailure, url: URL) {
        let state = AppState.shared
        ControlJournal.shared.record(ControlEvidence(
            operation: "automation:rejected",
            backend: "url-scheme",
            phase: .failed,
            target: nil,
            observed: nil,
            detail: failure.message + " · " + url.absoluteString
        ))
        state.statusNote = failure.message
        state.lastMessage = failure.message
    }

    // MARK: - status

    /// `infinical://status` writes one JSON object to a fixed path. A fixed
    /// path is what makes it usable from a shell: the caller does not have to
    /// discover it, and the file is replaced atomically so a read never sees
    /// half an object.
    static var statusURL: URL {
        CalibrationStore.directory.appendingPathComponent("status.json")
    }

    private func writeStatus() {
        let state = AppState.shared
        let sample = state.snapshot
        let payload: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "percentage": sample.isPresent ? sample.percentage : -1,
            "charging": sample.isCharging,
            "pluggedIn": sample.isPluggedIn,
            "paused": state.userPaused,
            "limit": state.chargeVal,
            "topUpRestore": state.topUpRestoreLimit.map { $0 as Any } ?? NSNull(),
            "temperature": sample.temperature,
            "state": state.chargeState.title,
            "strategy": state.capabilities.strategy.title,
            "helperInstalled": state.helperInstalled,
            "calibrating": CalibrationEngine.shared.isRunning,
            // The last thing the app said. Without it a script that got `false`
            // somewhere has no way to learn why short of opening the window.
            "note": state.statusNote,
            "sampledAt": ISO8601DateFormatter().string(from: sample.timestamp)
        ]
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = "{}"
        }
        do {
            try text.data(using: .utf8)?.write(to: Self.statusURL, options: .atomic)
            state.statusNote = tf("状态已写入 {p}", Self.statusURL.path)
        } catch {
            state.statusNote = tf("状态写入失败：{p}", error.localizedDescription)
        }
        state.lastMessage = state.statusNote
    }
}

// MARK: - AppState bridge

extension AppState {

    struct AutomationOutcome {
        var ok: Bool
        var message: String
    }

    /// The single place automation meets the levers. Each branch reuses the
    /// exact call the window makes, with `origin: .automation` so a script is
    /// never mistaken for the user.
    @discardableResult
    func perform(_ command: AutomationCommand) -> AutomationOutcome {
        guard helperInstalled || command == .status else {
            // Say what is missing instead of letting the write fail one layer
            // down with a system error that means nothing to a script author.
            return AutomationOutcome(ok: false, message: t("尚未安装特权助手，无法执行硬件控制。请在 InfiniCal 主窗口完成安装后重试。"))
        }
        switch command {
        case .limit(let value):
            let before = chargeVal
            setLimit(value, origin: .automation)
            let ok = chargeVal == value
            return AutomationOutcome(ok: ok,
                                     message: ok ? tf("充电上限已设为 {p}%（原 {p}%）", "\(value)", "\(before)")
                                                  : t("充电上限设置失败，请查看状态说明"))
        case .pause:
            let before = userPaused
            // `pauseCharging` reports whether the hardware write went through.
            // Intent alone is not a result: on a system-limit backend the write
            // is refused below the floor, and saying "paused" would be a lie.
            let stopped = pauseCharging(origin: .automation)
            if before && stopped {
                return AutomationOutcome(ok: true, message: t("充电已是暂停状态"))
            }
            if stopped || userPaused {
                return AutomationOutcome(ok: stopped,
                                         message: stopped ? t("充电已暂停")
                                                          : (statusNote.isEmpty ? t("暂停失败") : statusNote))
            }
            return AutomationOutcome(ok: false,
                                     message: statusNote.isEmpty ? t("暂停失败") : statusNote)
        case .resume:
            guard !userPaused else {
                resumeCharging()
                return AutomationOutcome(ok: true, message: t("已恢复充电"))
            }
            return AutomationOutcome(ok: true, message: t("充电未被暂停"))
        case .topUp(let value):
            let restore = chargeVal
            topUp(origin: .automation, target: value)
            let ok = topUpRestoreLimit != nil
            return AutomationOutcome(ok: ok,
                                     message: ok ? tf("已开始充电至 {p}%，完成后恢复 {p}%", "\(value)", "\(restore)")
                                                  : (statusNote.isEmpty ? t("一次性充满未能开始") : statusNote))
        case .discharge(let value):
            guard value < snapshot.percentage else {
                return AutomationOutcome(ok: false, message: tf("当前电量 {p}% 已不高于目标 {p}%，无需放电",
                                                               "\(snapshot.percentage)", "\(value)"))
            }
            let started = startDischarge(to: value, origin: .automation)
            return AutomationOutcome(ok: started,
                                     message: started ? tf("已开始放电至 {p}%", "\(value)")
                                                      : (statusNote.isEmpty ? t("放电未能开始") : statusNote))
        case .calibrate(let preset):
            guard !CalibrationEngine.shared.isRunning else {
                return AutomationOutcome(ok: false, message: t("校准进行中，请先结束当前会话"))
            }
            guard !CalibrationEngine.shared.needsRecovery else {
                return AutomationOutcome(ok: false, message: t("上一次校准需要安全恢复，请先在主窗口完成"))
            }
            // `beginCalibration` writes the specific reason ("请先连接电源适配器",
            // "恢复充电失败 — …") into `statusNote`. Returning a generic string
            // here would overwrite it one line later and leave the script with
            // no idea what to fix.
            let noteBefore = statusNote
            startCalibration(preset: preset, mode: .balanced, origin: .automation)
            if CalibrationEngine.shared.isRunning {
                return AutomationOutcome(ok: true, message: tf("已开始 {p}", preset.title))
            }
            let reason = statusNote != noteBefore && !statusNote.isEmpty
                ? statusNote
                : (CalibrationEngine.shared.startFailureReason ?? t("校准未能开始"))
            return AutomationOutcome(ok: false, message: reason)
        case .status:
            return AutomationOutcome(ok: true, message: "")
        }
    }
}
