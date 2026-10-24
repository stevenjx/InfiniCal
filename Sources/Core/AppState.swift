//
//  AppState.swift
//  Single source of truth: telemetry, settings, control loop, automation.
//

import Foundation
import SwiftUI
import AppKit
import ServiceManagement

enum Panel: String, CaseIterable, Identifiable {
    case dashboard
    case chargeControl
    case calibration
    case fanControl
    case sleep
    case history
    case schedule
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return t("仪表板")
        case .chargeControl: return t("充电控制")
        case .calibration: return t("电池校准")
        case .fanControl: return t("风扇控制")
        case .sleep: return t("睡眠与能源")
        case .history: return t("历史")
        case .schedule: return t("定时设置")
        case .other: return t("其他")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .chargeControl: return "battery.75"
        case .calibration: return "wrench.and.screwdriver"
        case .fanControl: return "fanblades"
        case .sleep: return "moon"
        case .history: return "chart.bar.xaxis"
        case .schedule: return "calendar.badge.clock"
        case .other: return "shippingbox"
        }
    }

    var category: String? {
        switch self {
        case .dashboard: return nil
        case .chargeControl, .calibration, .fanControl, .sleep, .history: return t("电池保养")
        case .schedule: return t("自动化")
        case .other: return t("外观")
        }
    }
}

final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: - Published state

    @Published var snapshot = BatterySnapshot()
    @Published var history = HistoryBuffers()
    @Published var livePower = PowerMeter.Reading()
    @Published var soc = PowerReading.unavailable
    @Published var displayPower = PowerReading.unavailable
    @Published var selectedPanel: Panel = .dashboard
    @Published var chargeState: ChargeState = .noAdapter
    @Published var capabilities = ChargeCapabilities()
    @Published var helperInstalled = false
    @Published var showFirstRunHelperPrompt = false
    @Published var highUsageApps: [HighUsageApp] = []
    @Published var calibration: CalibrationRun?
    @Published var tasks: [ScheduledTask] = []
    @Published var taskHistory: [TaskLogEntry] = []
    @Published var lastMessage: String?
    @Published var statusNote: String = ""

    // MARK: - Settings (persisted with the same keys AlDente uses where applicable)

    @Published var chargeVal: Int = 80 {
        didSet {
            store(chargeVal, "chargeVal")
            invalidateAppliedLimit()
            // A limit the user typed in means they took over; stop tracking the
            // one-shot top-up instead of overwriting their choice later.
            if !suppressTopUpCancel, topUpRestore != nil, chargeVal != 100 {
                topUpRestore = nil
                topUpDeadline = nil
                clearTopUpPersistence()
                statusNote = ""
            }
        }
    }
    @Published var allowBelow80: Bool = true {
        didSet {
            store(allowBelow80, "allowChargeLimitsBelow80")
            if !allowBelow80, chargeVal < 80 { chargeVal = 80 }
        }
    }
    @Published var automaticDischarge: Bool = true { didSet { store(automaticDischarge, "automaticDischarge") } }
    @Published var sailingMode: Bool = true { didSet { store(sailingMode, "sailingMode") } }
    @Published var sailingLevel: Int = 5 { didSet { store(sailingLevel, "sailingLevel") } }
    @Published var heatProtectMode: Bool = false { didSet { store(heatProtectMode, "heatProtectMode") } }
    @Published var maxTemperature: Int = 35 { didSet { store(maxTemperature, "maxTemperature") } }
    @Published var calibrationBackup: Int = 80 { didSet { store(calibrationBackup, "calibrationBackupPercentage") } }
    @Published var smartChargeEnabled: Bool = false { didSet { store(smartChargeEnabled, "smartChargeEnabled") } }
    @Published var smartChargeHour: Int = 9 { didSet { store(smartChargeHour, "smartChargeHour") } }
    @Published var smartChargeMinute: Int = 0 { didSet { store(smartChargeMinute, "smartChargeMinute") } }
    /// EWMA of the charge power this machine actually shows, used to schedule.
    @Published private(set) var chargeRateWatts: Double = 0
    @Published var sleepMode: Int = 0 { didSet { store(sleepMode, "sleepMode") } }
    @Published var exitInhibitCharge: Bool = false { didSet { store(exitInhibitCharge, "exitInhibitCharge") } }
    @Published var completelyDisableSleep: Bool = false {
        didSet {
            store(completelyDisableSleep, "completelyDisableSleep")
            applySleepAssertions()
        }
    }
    @Published var displayOffWhenSleepDisabled: Bool = true {
        didSet {
            store(displayOffWhenSleepDisabled, "displayOffWhenSleepDisabled")
            applySleepAssertions()
        }
    }
    @Published var lockScreenWhenClosed: Bool = false { didSet { store(lockScreenWhenClosed, "lockScreenWhenClosed") } }
    @Published var lpmPreference: Int = 0 { didSet { store(lpmPreference, "lpmPreference") } }
    @Published var dashboardBackgroundUpdates: Bool = false { didSet { store(dashboardBackgroundUpdates, "dashboardBackgroundUpdates") } }
    @Published var showProcessesInHighUsage: Bool = false { didSet { store(showProcessesInHighUsage, "showProcessesInHighUsage") } }
    @Published var energyThreshold: Int = 1 { didSet { store(energyThreshold, "appsSignificantEnergyThreshold") } }
    @Published var colorMode: Int = 2 { didSet { store(colorMode, "colorMode"); syncTheme() } }
    /// 0 = follow the system, 1 = Chinese, 2 = English. Every string is resolved
    /// through `t()` while a body is built, so publishing this is enough to
    /// re-render the whole interface in the new language.
    @Published var languageMode: Int = 0 {
        didSet {
            store(languageMode, "languageMode")
            L10n.applyPreference(languageMode)
        }
    }
    /// `.accessory` keeps the app out of the Dock and Cmd-Tab; the status item is
    /// then the only way back. Some users prefer a normal Dock icon, so this is a
    /// setting rather than a hard-coded policy.
    @Published var showInDock: Bool = true {
        didSet {
            store(showInDock, "showInDock")
            if NSApp.isRunning { applyDockPreference() }
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet {
            store(launchAtLogin, "launchAtLogin")
            // Loading defaults must not spawn `launchctl` on every launch; the
            // agent is reconciled explicitly once the app is up.
            if !isLoadingSettings { applyLaunchAtLogin() }
        }
    }
    @Published var startTasksAfterDue: Bool = false { didSet { store(startTasksAfterDue, "startTasksAfterDue") } }
    @Published var systemIsDark: Bool = true { didSet { syncTheme() } }

    // MARK: - Private

    private let defaults = UserDefaults.standard
    private let meter = PowerMeter()
    let flowTicker = FlowTicker()
    private let estimator = PowerEstimator()
    private var lastHelperSocPoll = Date.distantPast
    private var socRequestInFlight = false
    private var timer: Timer?
    private var taskTimer: Timer?
    private var lastAppliedLimit: Int?
    private var lastChargingAllowed: Bool?
    private var heatPause = false
    private var userPaused = false
    private var tickCount = 0

    /// One-shot top-up: raise the ceiling to 100 %, then put the user's limit
    /// back once the pack is full and unplugged, or when the safety window ends.
    private var topUpRestore: Int?
    private var topUpDeadline: Date?
    private var suppressTopUpCancel = false
    private var wakeObserver: NSObjectProtocol?
    private var lastDailySample: Date?
    private var previousPercentage = 0
    private var smartChargeStartedFor: Date?
    private var sleepObserver: NSObjectProtocol?
    private var sleepInhibited = false
    private var lastLidClosed = false
    private var isLoadingSettings = false


    // MARK: - Lifecycle

    var theme: Theme {
        colorMode == 0 ? Theme(isDark: systemIsDark) : Theme(isDark: colorMode == 2)
    }

    func syncTheme() {
        Theme.current = theme
    }

    /// Applied once at launch and again whenever the setting changes.
    func applyDockPreference() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private init() {
        Self.migrateLegacyInstallation()
        loadSettings()
        systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        syncTheme()
        loadHistory()
        helperInstalled = HelperClient.shared.refreshInstallState()
        showFirstRunHelperPrompt = !helperInstalled && !defaults.bool(forKey: "didShowFirstRunHelperPrompt")
        capabilities = ChargeController.shared.detectCapabilities()
        capabilities.hasHelper = helperInstalled
        snapshot = BatteryReader.read()
        // Populate SoC / display before the first frame. Without this the initial
        // model had those branches missing, so the flow card rendered a single
        // "其他" bar at launch and then rebuilt itself two seconds later.
        refreshComponentPower()
        // Also sample the live total now. Otherwise `flowModel` fell back to the
        // 60-second SystemLoad snapshot for the first frame and showed a wrong
        // "其他" share, then snapped to the real value one second later.
        livePower = meter.sample(fallback: snapshot)
        // Seed the ticker before the first frame. Without this the printed values
        // started at 0 and climbed by smoothing, so the card opened showing a
        // fraction of the real wattage.
        flowTicker.update(flowModel)
        updateChargeState()
        startTimers()
        observeWake()
        Notifier.shared.prepare()
        // A task that came due while the app was closed still has to run when
        // the user asked for that, otherwise 「周末充满」 only works if the app
        // happened to be open at 09:00.
        checkScheduledTasks(catchUp: startTasksAfterDue)
    }

    private var powerTimer: Timer?

    // MARK: - Rename migration (AIBattery → InfiniCal)

    /// The bundle identifier changed with the rename, so `UserDefaults` starts
    /// from a new domain and the data folder has a new name. Carry the old
    /// values over once, so settings and calibration history survive the
    /// upgrade, and retire the login item that pointed at the old binary.
    private static func migrateLegacyInstallation() {
        let defaults = UserDefaults.standard
        let doneKey = "didMigrateFromAIBattery"

        if !defaults.bool(forKey: doneKey) {
            if let legacy = defaults.persistentDomain(forName: "com.aibattery.app") {
                for (key, value) in legacy where defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
            defaults.set(true, forKey: doneKey)
        }

        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDirectory = support.appendingPathComponent("AIBattery", isDirectory: true)
        let currentDirectory = support.appendingPathComponent("InfiniCal", isDirectory: true)
        if manager.fileExists(atPath: legacyDirectory.path),
           !manager.fileExists(atPath: currentDirectory.path) {
            try? manager.moveItem(at: legacyDirectory, to: currentDirectory)
        }

        let legacyAgent = NSHomeDirectory() + "/Library/LaunchAgents/com.aibattery.app.plist"
        if manager.fileExists(atPath: legacyAgent) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(getuid())/com.aibattery.app"]
            try? process.run()
            try? manager.removeItem(atPath: legacyAgent)
        }
    }

    func startTimers() {
        powerTimer?.invalidate()
        let pt = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollLivePower() }
        RunLoop.main.add(pt, forMode: .common)
        powerTimer = pt
        timer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        taskTimer?.invalidate()
        let tt = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in self?.checkScheduledTasks() }
        RunLoop.main.add(tt, forMode: .common)
        taskTimer = tt
    }

    /// Timers stop while the machine sleeps, so wake is the moment to rebuild
    /// whatever the SMC may have forgotten and to run the tasks that came due.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }
    }

    /// 「睡眠时停止充电」/「睡眠时充满后停止充电」: the process is suspended during
    /// sleep, so the decision has to be made before the machine goes down.
    private func handleWillSleep() {
        switch sleepMode {
        case 1:
            inhibitChargingForSleep()
        case 2:
            if snapshot.percentage >= max(99, chargeVal) { inhibitChargingForSleep() }
        default:
            break
        }
    }

    private func inhibitChargingForSleep() {
        do {
            try ChargeController.shared.setChargingAllowed(false)
            sleepInhibited = true
            lastChargingAllowed = false
            log(t("睡眠"), t("已按设置暂停充电"))
        } catch {
            statusNote = tf("睡眠前暂停充电失败：{p}", error.localizedDescription)
        }
    }

    // MARK: - Sleep assertions & lid lock

    private func applySleepAssertions() {
        SleepControl.shared.apply(disableSleep: completelyDisableSleep,
                                  allowDisplaySleep: displayOffWhenSleepDisabled)
    }

    /// Polled from the 2 s tick: the IORegistry has no change notification for
    /// the lid, and 2 s is fast enough to catch a clamshell close.
    private func checkLidLock() {
        guard lockScreenWhenClosed else {
            lastLidClosed = false
            return
        }
        let closed = SleepControl.shared.isLidClosed()
        if closed, !lastLidClosed {
            if !SleepControl.shared.lockScreen() {
                statusNote = t("当前系统未提供锁屏接口")
            }
        }
        lastLidClosed = closed
    }

    private func handleWake() {
        // The SMC may have dropped the forced ceiling or the charge inhibit bit
        // during sleep; clearing these makes the next tick write them again.
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        heatPause = false
        if sleepInhibited { sleepInhibited = false }
        helperInstalled = HelperClient.shared.refreshInstallState()
        capabilities = ChargeController.shared.detectCapabilities()
        capabilities.hasHelper = helperInstalled
        tick()
        checkScheduledTasks(catchUp: startTasksAfterDue)
    }

    private func pollLivePower() {
        // Same switch as the chart history: no 2 Hz sampling for a window the
        // user is not looking at.
        guard dashboardBackgroundUpdates || NSApp.isActive else { return }
        let reading = meter.sample(fallback: snapshot)
        if reading.total > 0.01 || livePower.total == 0 {
            livePower = reading
        }
        flowTicker.update(flowModel)
    }

    private func tick() {
        tickCount += 1
        snapshot = BatteryReader.read()
        recordDailyEnergy()
        refreshComponentPower()
        checkLidLock()
        // Chart history is only for the dashboard; 「后台仪表板更新」 decides
        // whether it keeps filling while the window is not frontmost.
        if dashboardBackgroundUpdates || NSApp.isActive {
            history.append(battery: Double(snapshot.percentage),
                           temperature: snapshot.temperature,
                           power: energyUseWatts,
                           capacity: Double(snapshot.healthPercent),
                           limit: chargeVal)
        }
        // A running calibration owns the charge hardware; the normal limit loop
        // must stay out of its way until the session ends.
        if calibrationEngine.isRunning {
            mirrorCalibration()
        } else {
            if calibration != nil { endCalibrationMirror() }
            evaluateSmartCharge()
            evaluateTopUp()
            evaluateChargeControl()
        }
        updateChargeState()
        notifyLimitReached()
        // `ps` is a process spawn; skip it while nobody can see the list.
        if tickCount % 10 == 0, dashboardBackgroundUpdates || NSApp.isActive {
            refreshEnergyApps()
        }
        if tickCount % 30 == 0 {
            helperInstalled = HelperClient.shared.refreshInstallState()
            DailyHistory.shared.save()
        }
        // ~150 KB of JSON per write. Five minutes is plenty for a rolling
        // three-hour window, and a crash loses at most that much.
        if tickCount % 150 == 0 { saveHistory() }
    }

    // MARK: - Long-term history
    //
    // Same telemetry as the dashboard charts, folded into one row per day. The
    // 2 s tick is the sample interval, so the energy comes from the pack's own
    // voltage × current rather than from an estimate.

    private func recordDailyEnergy() {
        let now = Date()
        let seconds = now.timeIntervalSince(lastDailySample ?? now)
        lastDailySample = now
        // A gap means the process was suspended; integrating across it would
        // invent energy that never moved.
        guard seconds > 0, seconds < 60 else { return }

        // Same rule as the calibration engine: the filtered gauge current lags
        // real load steps, so prefer the instantaneous value when it is sane.
        let current = abs(snapshot.instantAmperage) >= 0.02 ? snapshot.instantAmperage : snapshot.amperage
        let watts = snapshot.voltage * current
        DailyHistory.shared.accumulate(chargeWh: max(0, watts) * seconds / 3600,
                                       dischargeWh: max(0, -watts) * seconds / 3600,
                                       temperature: snapshot.temperature,
                                       percentage: snapshot.percentage,
                                       plugged: snapshot.isPluggedIn,
                                       health: snapshot.healthPercent,
                                       cycleCount: snapshot.cycleCount,
                                       seconds: seconds)
    }

    /// One banner per crossing of the ceiling, not one per tick. A limit change
    /// that puts the ceiling below the current charge is not a crossing.
    private func notifyLimitReached() {
        let current = snapshot.percentage
        defer { previousPercentage = current }
        guard snapshot.isPluggedIn, !heatPause,
              previousPercentage > 0,
              previousPercentage < chargeVal,
              current >= chargeVal else { return }

        if chargeVal >= 100 {
            Notifier.shared.post(key: "battery-full",
                                 title: t("电池已充满"),
                                 body: t("已充至 100%，可以拔下电源。"),
                                 cooldown: 3600)
        } else {
            Notifier.shared.post(key: "charge-limit",
                                 title: tf("已充至 {p}%", "\(chargeVal)"),
                                 body: t("充电已暂停，电池保持在设定上限。"),
                                 cooldown: 3600)
        }
    }

    // MARK: - Charge control

    private func evaluateChargeControl() {
        guard snapshot.isPresent else { chargeState = .noBattery; return }
        guard snapshot.isPluggedIn else {
            chargeState = .noAdapter
            if lastChargingAllowed != true { lastChargingAllowed = nil }
            return
        }

        if heatProtectMode, snapshot.temperature >= Double(maxTemperature) {
            heatPause = true
            statusNote = String(format: t("电池温度 %.1f°C 超过上限 %d°C，充电已暂停"), snapshot.temperature, maxTemperature)
            setCharging(false)
            Notifier.shared.post(key: "heat-protect",
                                 title: t("过热保护已触发"),
                                 body: String(format: t("电池温度 %.1f°C 超过上限 %d°C，充电已暂停。"), snapshot.temperature, maxTemperature),
                                 cooldown: 900)
            return
        }
        if heatPause {
            if snapshot.temperature <= Double(maxTemperature) - 2 {
                heatPause = false
                statusNote = ""
                lastChargingAllowed = nil
                Notifier.shared.post(key: "heat-recovered",
                                     title: t("温度已恢复"),
                                     body: t("电池已降温，充电恢复。"),
                                     cooldown: 900)
            } else {
                return
            }
        }

        let limit = chargeVal
        if lastAppliedLimit != limit {
            lastAppliedLimit = limit
            do {
                try ChargeController.shared.applyChargeLimit(limit)
            } catch {
                // Software enforcement still applies; surface the error once.
                if capabilities.strategy == .unavailable {
                    statusNote = error.localizedDescription
                }
            }
        }

        var desired: Bool
        if snapshot.percentage >= limit {
            desired = false
        } else if sailingMode && snapshot.percentage <= limit - sailingLevel {
            desired = true
        } else if snapshot.percentage <= limit - 1 {
            desired = lastChargingAllowed ?? true
        } else {
            desired = lastChargingAllowed ?? false
        }
        if !automaticDischarge, snapshot.percentage > limit {
            desired = false
        }
        setCharging(desired)
    }

    private func setCharging(_ allowed: Bool) {
        guard lastChargingAllowed != allowed else { return }
        do {
            try ChargeController.shared.setChargingAllowed(allowed)
            lastChargingAllowed = allowed
        } catch {
            lastChargingAllowed = allowed
        }
    }

    /// Forces the next tick to write the ceiling again.
    private func invalidateAppliedLimit() {
        lastAppliedLimit = nil
    }

    private func updateChargeState() {
        if calibration != nil { chargeState = .calibrating; return }
        if !snapshot.isPresent { chargeState = .noBattery; return }
        if !snapshot.isPluggedIn { chargeState = .noAdapter; return }
        if heatPause { chargeState = .paused; return }
        if snapshot.fullyCharged || snapshot.percentage >= 100 { chargeState = .full; return }
        if snapshot.isCharging { chargeState = .charging; return }
        if snapshot.percentage > chargeVal { chargeState = .paused; return }
        chargeState = .paused
    }

    // MARK: - One-shot top-up
    //
    // 「充满」used to set chargeVal = 100 permanently, so a single tap (or the
    // 「周末充满」template) silently cancelled the user's charge limit for good.
    // It is now an override with an end: the pack charges to 100 %, then the
    // previous limit comes back once it is full and unplugged, or after four
    // hours, whichever happens first.

    var topUpRestoreLimit: Int? { topUpRestore }

    func topUp() {
        if topUpRestore == nil { topUpRestore = chargeVal }
        let restore = topUpRestore ?? chargeVal
        userPaused = false
        suppressTopUpCancel = true
        chargeVal = 100
        suppressTopUpCancel = false
        topUpDeadline = Date().addingTimeInterval(4 * 3600)
        persistTopUp()
        lastChargingAllowed = nil
        statusNote = tf("一次性充满至 100%，完成后恢复 {p}%", "\(restore)")
        log(t("充满"), tf("一次性充满至 100%，完成后恢复 {p}%", "\(restore)"))
    }

    func cancelTopUp() {
        guard let restore = topUpRestore else { return }
        finishTopUp(restore: restore, reason: t("已取消"), notify: false)
    }

    private func evaluateTopUp() {
        guard let restore = topUpRestore else { return }
        let full = snapshot.percentage >= 99
        if let deadline = topUpDeadline, Date() >= deadline {
            finishTopUp(restore: restore, reason: t("已超过 4 小时"))
        } else if full, !snapshot.isPluggedIn {
            finishTopUp(restore: restore, reason: t("已充满并拔下电源"))
        }
    }

    private func finishTopUp(restore: Int, reason: String, notify: Bool = true) {
        suppressTopUpCancel = true
        topUpRestore = nil
        topUpDeadline = nil
        clearTopUpPersistence()
        smartChargeStartedFor = nil
        chargeVal = restore
        suppressTopUpCancel = false
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        statusNote = tf("一次性充满{p}，充电限制已恢复为 {p}%", reason, "\(restore)")
        log(t("充满"), statusNote)
        if notify {
            Notifier.shared.post(key: "top-up-finished",
                                 title: t("一次性充满完成"),
                                 body: tf("充电限制已恢复为 {p}%。", "\(restore)"),
                                 cooldown: 60)
        }
    }

    /// The override has to survive a relaunch: quitting in the middle of a
    /// top-up used to leave the limit at 100 % for good.
    private func persistTopUp() {
        defaults.set(topUpRestore, forKey: "topUpRestoreLimit")
        defaults.set(topUpDeadline?.timeIntervalSince1970, forKey: "topUpDeadline")
    }

    private func clearTopUpPersistence() {
        defaults.removeObject(forKey: "topUpRestoreLimit")
        defaults.removeObject(forKey: "topUpDeadline")
    }

    // MARK: - Scheduled top-up（按时间充满）
    //
    // The pack sits at the normal ceiling all day; this raises it just early
    // enough that 100 % lands on the requested time. The lead time comes from
    // the energy still missing divided by the charge rate this machine has
    // actually shown, plus a margin for the taper at the top.

    var smartChargeTarget: Date? {
        guard smartChargeEnabled else { return nil }
        if let started = smartChargeStartedFor { return started }
        return nextSmartChargeTarget()
    }

    var smartChargeStartDate: Date? {
        guard let target = smartChargeTarget, snapshot.isPresent else { return nil }
        let rate = max(5, chargeRateWatts > 0 ? chargeRateWatts : Double(snapshot.adapter.watts) * 0.75)
        let hours = missingEnergyWh / rate * 1.25
        return target.addingTimeInterval(-(hours * 3600 + 300))
    }

    var smartChargeStatusText: String {
        guard smartChargeEnabled else { return "" }
        guard snapshot.isPresent else { return t("未检测到电池") }
        guard snapshot.isPluggedIn else { return t("等待接入电源") }
        if snapshot.percentage >= 100 { return t("已充满") }
        guard let target = smartChargeTarget else { return "" }
        if topUpRestore != nil {
            return tf("正在充电，预计 {p} 充满", Self.clock.string(from: target))
        }
        guard let start = smartChargeStartDate else { return "" }
        if Date() >= start {
            return tf("即将开始充电，预计 {p} 充满", Self.clock.string(from: target))
        }
        let minutes = max(1, Int(target.timeIntervalSince(start) / 60))
        return tf("将在 {p} 开始，约 {p} 分钟后充满", Self.clock.string(from: start), "\(minutes)")
    }

    private var missingEnergyWh: Double {
        let full = Double(snapshot.maxCapacity) / 1000 * max(7, snapshot.voltage)
        let missing = Double(max(0, 100 - snapshot.percentage)) / 100
        return full * missing
    }

    private func nextSmartChargeTarget() -> Date? {
        let calendar = Calendar.current
        let now = Date()
        guard var target = calendar.date(bySettingHour: smartChargeHour,
                                         minute: smartChargeMinute,
                                         second: 0,
                                         of: now) else { return nil }
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    private func evaluateSmartCharge() {
        guard smartChargeEnabled, snapshot.isPresent, snapshot.isPluggedIn else { return }

        // Learn the real charge rate while it is charging; the schedule is only
        // as good as this number.
        if snapshot.isCharging, snapshot.amperage > 0.1 {
            let watts = snapshot.voltage * snapshot.amperage
            if watts > 1, watts < 200 {
                chargeRateWatts = chargeRateWatts > 0 ? chargeRateWatts * 0.9 + watts * 0.1 : watts
                defaults.set(chargeRateWatts, forKey: "chargeRateWatts")
            }
        }

        guard snapshot.percentage < 100, topUpRestore == nil,
              let target = nextSmartChargeTarget(),
              let start = smartChargeStartDate,
              Date() >= start else { return }

        smartChargeStartedFor = target
        topUp()
        statusNote = tf("按时间充满：已开始充电，预计 {p} 充满", Self.clock.string(from: target))
    }

    // MARK: - Adapter diagnosis

    struct AdapterDiagnosis {
        enum Level { case good, tight, insufficient }
        var level: Level
        var ratedWatts: Double
        var inputWatts: Double
        var systemWatts: Double
        var batteryWatts: Double
        var headroomWatts: Double
        var lossWatts: Double
        var lossPercent: Double
    }

    var adapterDiagnosis: AdapterDiagnosis? {
        guard snapshot.isPresent, snapshot.isPluggedIn else { return nil }
        let input = snapshot.adapter.power > 0.05 ? snapshot.adapter.power : snapshot.systemPowerIn
        let battery = snapshot.voltage * snapshot.amperage
        let system = max(0, input - battery)
        let rated = Double(snapshot.adapter.watts)
        // Spare capacity is measured against the rating, not against the input:
        // a 96 W brick idling at 18 W has 78 W spare, while a throttled one that
        // cannot cover the system shows the deficit instead.
        let ratedHeadroom = rated > 0 ? rated - system : input - system
        let headroom = battery < -0.3 ? input - system : ratedHeadroom
        let loss = snapshot.adapterEfficiencyLoss
        let percent = input > 0.5 ? max(0, loss) / input * 100 : 0

        let level: AdapterDiagnosis.Level
        if battery < -0.3 {
            // The pack is being drained while plugged in: the adapter cannot
            // cover the system, whatever its label says.
            level = .insufficient
        } else if rated > 0, ratedHeadroom < max(2, rated * 0.1) {
            level = .tight
        } else {
            level = .good
        }

        return AdapterDiagnosis(level: level,
                                ratedWatts: rated,
                                inputWatts: input,
                                systemWatts: system,
                                batteryWatts: battery,
                                headroomWatts: headroom,
                                lossWatts: loss,
                                lossPercent: percent)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func pauseCharging() {
        userPaused = true
        // Pausing overrides a running top-up: the user asked for it to stop.
        topUpRestore = nil
        topUpDeadline = nil
        clearTopUpPersistence()
        smartChargeStartedFor = nil
        lastChargingAllowed = nil
        setCharging(false)
        statusNote = t("充电已暂停")
    }


    // MARK: - Calibration
    //
    // The session itself lives in CalibrationEngine (1 Hz measurement, phase
    // machine, SMC control). AppState keeps a coarse mirror so the dashboard
    // card and the charge-state pill stay correct, and restores the user's
    // charge limit when the session ends.

    private var calibrationEngine: CalibrationEngine { CalibrationEngine.shared }

    func startCalibration() {
        guard !calibrationEngine.isRunning else { return }
        // A calibration owns the charge ceiling end to end; drop any pending
        // top-up so its restore value cannot fire in the middle of a session.
        topUpRestore = nil
        topUpDeadline = nil
        clearTopUpPersistence()
        smartChargeStartedFor = nil
        calibration = CalibrationRun(stage: .chargeToFull, startedAt: Date())
        lastAppliedLimit = nil
        chargeVal = 100
        statusNote = t("校准已开始：正在充电至 100%")
        calibrationEngine.start()
        log(t("校准"), t("校准模式已启动"))
    }

    func stopCalibration() {
        calibrationEngine.stop()
        calibration = nil
        chargeVal = calibrationBackup
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        statusNote = t("校准已取消")
        log(t("校准"), t("校准模式已取消"))
    }

    private func mirrorCalibration() {
        guard let stage = calibrationEngine.phase.stage else { return }
        if calibration?.stage != stage {
            calibration = CalibrationRun(stage: stage,
                                         startedAt: calibration?.startedAt ?? Date(),
                                         holdUntil: calibration?.holdUntil)
        }
        if chargeVal != 100 {
            chargeVal = 100
            lastAppliedLimit = nil
        }
    }

    private func endCalibrationMirror() {
        let finished = calibrationEngine.phase == .completed
        calibration = nil
        chargeVal = calibrationBackup
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        statusNote = finished ? t("校准完成") : t("校准已取消")
        log(t("校准"), statusNote)
    }

    var lastCalibrationDate: Date? {
        let stamp = defaults.double(forKey: "lastCalibrationTimestamp")
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    private func startDischargeInternal(to target: Int) {
        do {
            if capabilities.strategy == .bclm {
                try HelperClient.shared.smcWrite("BCLM", UInt8(max(0, min(100, target))))
            }
            try ChargeController.shared.setChargingAllowed(false)
        } catch { }
    }

    func startDischarge(to target: Int) {
        guard snapshot.isPluggedIn else {
            statusNote = t("仅连接充电器时才能设置放电")
            return
        }
        startDischargeInternal(to: target)
        statusNote = tf("放电至 {p}%", "\(target)")
        log(t("放电"), tf("开始放电至 {p}%", "\(target)"))
    }

    // MARK: - Scheduled tasks

    /// `catchUp` is the 「自动补做未完成的任务」 path: a task whose time passed
    /// while the Mac slept, or while the app was closed, still runs — once.
    func checkScheduledTasks(catchUp: Bool = false) {
        let now = Date()
        var changed = false
        for index in tasks.indices where isDue(tasks[index], at: now, catchUp: catchUp) {
            let task = tasks[index]
            run(task)
            tasks[index].lastRun = now
            changed = true
        }
        if changed { saveTasks() }
    }

    private func isDue(_ task: ScheduledTask, at now: Date, catchUp: Bool) -> Bool {
        guard task.enabled else { return false }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        guard task.weekdays.contains(isoWeekday) else { return false }

        guard let scheduled = calendar.date(bySettingHour: task.hour,
                                            minute: task.minute,
                                            second: 0,
                                            of: now) else { return false }
        let lateness = now.timeIntervalSince(scheduled)
        guard lateness >= 0 else { return false }
        // A normal tick only looks at the current minute; catch-up accepts a
        // task up to 12 hours late before treating it as stale.
        guard lateness < (catchUp ? 12 * 3600 : 120) else { return false }

        guard let last = task.lastRun else { return true }
        if catchUp { return !calendar.isDate(last, inSameDayAs: now) }
        return now.timeIntervalSince(last) > 300
    }

    func run(_ task: ScheduledTask) {
        switch task.kind {
        case .topUp:
            topUp()
        case .stopCharging:
            pauseCharging()
        case .startDischarge:
            startDischarge(to: task.value)
        case .calibrate:
            startCalibration()
        case .setLimit:
            chargeVal = task.value
            lastAppliedLimit = nil
            log(t("设置充电限制"), tf("已设为 {p}%", "\(task.value)"))
        }
        taskHistory.insert(TaskLogEntry(date: Date(), title: task.kind.title, detail: "\(task.timeText) · \(task.weekdayText)"), at: 0)
        if taskHistory.count > 50 { taskHistory.removeLast() }
        saveTasks()
    }

    func addTask(_ task: ScheduledTask) {
        tasks.append(task)
        saveTasks()
    }

    func removeTask(_ task: ScheduledTask) {
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    func clearTaskHistory() {
        taskHistory.removeAll()
        saveTasks()
    }

    private func log(_ title: String, _ detail: String) {
        taskHistory.insert(TaskLogEntry(date: Date(), title: title, detail: detail), at: 0)
        if taskHistory.count > 50 { taskHistory.removeLast() }
        saveTasks()
    }

    private func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) { defaults.set(data, forKey: "scheduledTasks") }
        if let data = try? JSONEncoder().encode(taskHistory) { defaults.set(data, forKey: "taskHistory") }
    }

    // MARK: - Energy apps

    /// `ps` gives CPU share, not joules, so this list is labelled as CPU impact
    /// rather than energy. 「显示上方应用」 sets the cut-off; 「包含后台进程」
    /// decides whether processes without a UI are listed too.
    func refreshEnergyApps() {
        let output = shell("/bin/ps", ["-A", "-o", "pcpu=,comm="])
        var cpuByPath: [String: Double] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0]) else { continue }
            cpuByPath[String(parts[1])] = cpu
        }

        let threshold = energyThresholdValue
        var result: [HighUsageApp] = []
        var matchedPaths = Set<String>()

        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier != nil {
            guard let url = app.bundleURL else { continue }
            matchedPaths.insert(url.path)
            if !showProcessesInHighUsage, app.activationPolicy != .regular { continue }
            let cpu = cpuByPath[url.path] ?? 0
            guard cpu >= threshold else { continue }
            result.append(HighUsageApp(bundleID: app.bundleIdentifier ?? url.lastPathComponent,
                                       name: app.localizedName ?? url.lastPathComponent,
                                       energyImpact: cpu,
                                       icon: app.icon))
        }

        if showProcessesInHighUsage {
            for (path, cpu) in cpuByPath where !matchedPaths.contains(path) && cpu >= threshold {
                result.append(HighUsageApp(bundleID: path,
                                           name: (path as NSString).lastPathComponent,
                                           energyImpact: cpu,
                                           icon: nil))
            }
        }

        highUsageApps = result.sorted { $0.energyImpact > $1.energyImpact }
    }

    /// 0 = 低使用量 (list more), 1 = macOS 默认, 2 = 高使用量 (only heavy hitters).
    private var energyThresholdValue: Double {
        switch energyThreshold {
        case 0: return 0.2
        case 2: return 3.0
        default: return 1.0
        }
    }

    private func shell(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    // MARK: - Helper

    func dismissFirstRunHelperPrompt() {
        showFirstRunHelperPrompt = false
        defaults.set(true, forKey: "didShowFirstRunHelperPrompt")
    }

    func installHelper() {
        do {
            try HelperClient.shared.install()
            helperInstalled = true
            showFirstRunHelperPrompt = false
            defaults.set(true, forKey: "didShowFirstRunHelperPrompt")
            capabilities = ChargeController.shared.detectCapabilities()
            capabilities.hasHelper = true
            lastMessage = t("特权助手已安装")
        } catch {
            lastMessage = error.localizedDescription
        }
    }



    // MARK: - Appearance / login item

    /// macOS 13+ registers the app through `SMAppService`, which is the only
    /// route that survives being launched from a TCC-protected folder: a hand
    /// written LaunchAgent pointing at `~/Documents/...` is rejected by launchd
    /// with a bare "Input/output error". macOS 12 falls back to the agent.
    func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            applyLegacyLaunchAgent()
            return
        }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // A failed registration must not leave the switch claiming success.
            statusNote = tf("开机自启设置失败：{p}", error.localizedDescription)
            isLoadingSettings = true
            launchAtLogin = !launchAtLogin
            store(launchAtLogin, "launchAtLogin")
            isLoadingSettings = false
        }
    }

    /// Keeps the switch honest: the user can also remove the login item in
    /// System Settings, and the legacy agent can go stale after the app moves.
    func reconcileLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let registered = SMAppService.mainApp.status == .enabled
            if registered != launchAtLogin, !isLoadingSettings {
                isLoadingSettings = true
                launchAtLogin = registered
                store(launchAtLogin, "launchAtLogin")
                isLoadingSettings = false
            }
            return
        }
        let path = NSHomeDirectory() + "/Library/LaunchAgents/com.infinitycomputer.infinical.plist"
        guard launchAtLogin else {
            if FileManager.default.fileExists(atPath: path) { applyLegacyLaunchAgent() }
            return
        }
        let expected = Bundle.main.bundlePath + "/Contents/MacOS/InfiniCal"
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !current.contains(expected) { applyLegacyLaunchAgent() }
    }

    private func applyLegacyLaunchAgent() {
        let label = "com.infinitycomputer.infinical"
        let path = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        if launchAtLogin {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>\(Bundle.main.bundlePath)/Contents/MacOS/InfiniCal</string></array>
            <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                                     withIntermediateDirectories: true)
            try? plist.write(toFile: path, atomically: true, encoding: .utf8)
            _ = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path])
        } else {
            _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - History persistence

    private var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfiniCal", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    func saveHistory() {
        struct Stored: Codable { var battery: [HistoryPoint]; var temperature: [HistoryPoint]; var power: [HistoryPoint]; var capacity: [HistoryPoint] }
        let stored = Stored(battery: history.battery.suffix(600).map { $0 },
                            temperature: history.temperature.suffix(600).map { $0 },
                            power: history.power.suffix(600).map { $0 },
                            capacity: history.capacity.suffix(600).map { $0 })
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    private func loadHistory() {
        struct Stored: Codable { var battery: [HistoryPoint]; var temperature: [HistoryPoint]; var power: [HistoryPoint]; var capacity: [HistoryPoint]? }
        guard let data = try? Data(contentsOf: historyURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-60 * 60 * 3)
        history.battery = stored.battery.filter { $0.date > cutoff }
        history.temperature = stored.temperature.filter { $0.date > cutoff }
        history.power = stored.power.filter { $0.date > cutoff }
        history.capacity = (stored.capacity ?? []).filter { $0.date > cutoff }
    }

    // MARK: - Persistence

    private func store<T>(_ value: T, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        chargeVal = int("chargeVal", 80)
        // A top-up that was still running when the app quit picks up where it
        // left off; if its deadline passed meanwhile, the first tick restores.
        if defaults.object(forKey: "topUpRestoreLimit") != nil {
            topUpRestore = defaults.integer(forKey: "topUpRestoreLimit")
            let stamp = defaults.double(forKey: "topUpDeadline")
            topUpDeadline = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        allowBelow80 = bool("allowChargeLimitsBelow80", true)
        automaticDischarge = bool("automaticDischarge", true)
        sailingMode = bool("sailingMode", true)
        sailingLevel = int("sailingLevel", 5)
        heatProtectMode = bool("heatProtectMode", false)
        maxTemperature = int("maxTemperature", 35)
        calibrationBackup = int("calibrationBackupPercentage", 80)
        smartChargeEnabled = bool("smartChargeEnabled", false)
        smartChargeHour = int("smartChargeHour", 9)
        smartChargeMinute = int("smartChargeMinute", 0)
        chargeRateWatts = defaults.double(forKey: "chargeRateWatts")
        sleepMode = int("sleepMode", 0)
        // The advanced 「睡眠时停止充电」 switch was folded into the picker; carry
        // an existing preference over instead of dropping it on the floor.
        if bool("sleepInhibitCharge", false), sleepMode == 0 { sleepMode = 1 }
        exitInhibitCharge = bool("exitInhibitCharge", false)
        completelyDisableSleep = bool("completelyDisableSleep", false)
        displayOffWhenSleepDisabled = bool("displayOffWhenSleepDisabled", true)
        lockScreenWhenClosed = bool("lockScreenWhenClosed", false)
        lpmPreference = int("lpmPreference", 0)
        dashboardBackgroundUpdates = bool("dashboardBackgroundUpdates", false)
        showProcessesInHighUsage = bool("showProcessesInHighUsage", false)
        energyThreshold = int("appsSignificantEnergyThreshold", 1)
        colorMode = int("colorMode", 2)
        languageMode = int("languageMode", 0)
        showInDock = bool("showInDock", true)
        launchAtLogin = bool("launchAtLogin", false)
        startTasksAfterDue = bool("startTasksAfterDue", false)
        if let data = defaults.data(forKey: "scheduledTasks"),
           let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            tasks = decoded
        }
        if let data = defaults.data(forKey: "taskHistory"),
           let decoded = try? JSONDecoder().decode([TaskLogEntry].self, from: data) {
            taskHistory = decoded
        }
        // The two sleep switches are loaded in either order; settle the
        // assertion combination once both are known.
        applySleepAssertions()
    }

    // MARK: - Derived values

    var limitMarkerFraction: Double { Double(chargeVal) / 100.0 }


    var flowModel: PowerFlowModel {
        let socReading: PowerReading = soc
        let displayReading: PowerReading = displayPower
        return PowerFlowModel.make(from: snapshot,
                                   liveTotal: livePower.total,
                                   totalIsLive: livePower.isLive,
                                   soc: socReading,
                                   display: displayReading)
    }

    /// Total power currently drawn (live SMC reading, 5 Hz).
    var totalPowerWatts: Double {
        livePower.total > 0.01 ? livePower.total : snapshot.systemLoad
    }

    /// Power actually leaving the battery, in watts. Zero on AC (the pack is
    /// being filled, not drained), otherwise the measured discharge rate.
    var dischargeWatts: Double {
        snapshot.isPluggedIn ? 0 : max(0, -snapshot.voltage * snapshot.amperage)
    }

    /// "耗电量" as shown on the dashboard: what the machine consumes right now.
    /// On battery that is the discharge rate; on AC it is the system draw, since
    /// the pack is not supplying anything. The chart history uses this same value
    /// so the number and the curve always describe one quantity.
    var energyUseWatts: Double {
        snapshot.isPluggedIn ? totalPowerWatts : dischargeWatts
    }

    /// SoC: measured through powermetrics when the helper is installed (root),
    /// otherwise a labelled estimate. Display: always a labelled estimate on this
    /// platform because no backlight power counter exists.
    ///
    /// powermetrics is run by the root daemon, so its cost never appears in this
    /// process — asking for it every 8 s in the background is invisible in
    /// Activity Monitor and still wakes the machine. Nothing renders these two
    /// values but the flow diagram, so they are only refreshed while the app is
    /// actually on screen.
    private func refreshComponentPower() {
        guard dashboardBackgroundUpdates || NSApp.isActive else { return }
        let now = Date()
        if helperInstalled, !socRequestInFlight, now.timeIntervalSince(lastHelperSocPoll) > 8 {
            lastHelperSocPoll = now
            socRequestInFlight = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let measured = HelperClient.shared.socPower()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.socRequestInFlight = false
                    if let measured {
                        self.soc = .measured(measured)
                    } else {
                        self.soc = self.estimator.estimateSoC()
                    }
                }
            }
        } else if soc.quality != .measured {
            soc = estimator.estimateSoC()
        }

        if displayPower.quality != .measured {
            displayPower = estimator.estimateDisplay()
        }
    }
}
