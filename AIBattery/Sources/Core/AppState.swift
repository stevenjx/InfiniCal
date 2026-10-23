//
//  AppState.swift
//  Single source of truth: telemetry, settings, control loop, automation.
//

import Foundation
import SwiftUI
import AppKit

enum Panel: String, CaseIterable, Identifiable {
    case dashboard
    case chargeControl
    case sleep
    case energy
    case schedule
    case shortcuts
    case clamshell
    case menuBar
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "仪表板"
        case .chargeControl: return "充电控制"
        case .sleep: return "睡眠行为"
        case .energy: return "能源使用"
        case .schedule: return "定时设置"
        case .shortcuts: return "捷径"
        case .clamshell: return "翻盖"
        case .menuBar: return "菜单栏"
        case .other: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .chargeControl: return "battery.75"
        case .sleep: return "moon"
        case .energy: return "leaf"
        case .schedule: return "calendar.badge.clock"
        case .shortcuts: return "command"
        case .clamshell: return "laptopcomputer"
        case .menuBar: return "menubar.rectangle"
        case .other: return "shippingbox"
        }
    }

    var category: String? {
        switch self {
        case .dashboard: return nil
        case .chargeControl, .sleep, .energy: return "电池保养"
        case .schedule, .shortcuts: return "自动化"
        case .clamshell, .menuBar, .other: return "外观"
        }
    }
}

final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: - Published state

    @Published var snapshot = BatterySnapshot()
    @Published var history = HistoryBuffers()
    @Published var power = PowerSampler.Reading()
    @Published var livePower = PowerMeter.Reading()
    @Published var soc = PowerReading.unavailable
    @Published var displayPower = PowerReading.unavailable
    @Published var selectedPanel: Panel = .dashboard
    @Published var chargeState: ChargeState = .noAdapter
    @Published var capabilities = ChargeCapabilities()
    @Published var helperInstalled = false
    @Published var highUsageApps: [HighUsageApp] = []
    @Published var calibration: CalibrationRun?
    @Published var tasks: [ScheduledTask] = []
    @Published var taskHistory: [TaskLogEntry] = []
    @Published var lastMessage: String?
    @Published var statusNote: String = ""

    // MARK: - Settings (persisted with the same keys AlDente uses where applicable)

    @Published var chargeVal: Int = 80 { didSet { store(chargeVal, "chargeVal"); applyChargeLimitIfNeeded() } }
    @Published var allowBelow80: Bool = true { didSet { store(allowBelow80, "allowChargeLimitsBelow80") } }
    @Published var automaticDischarge: Bool = true { didSet { store(automaticDischarge, "automaticDischarge") } }
    @Published var sailingMode: Bool = true { didSet { store(sailingMode, "sailingMode") } }
    @Published var sailingLevel: Int = 5 { didSet { store(sailingLevel, "sailingLevel") } }
    @Published var heatProtectMode: Bool = false { didSet { store(heatProtectMode, "heatProtectMode") } }
    @Published var maxTemperature: Int = 35 { didSet { store(maxTemperature, "maxTemperature") } }
    @Published var calibrationBackup: Int = 80 { didSet { store(calibrationBackup, "calibrationBackupPercentage") } }
    @Published var sleepMode: Int = 0 { didSet { store(sleepMode, "sleepMode") } }
    @Published var sleepInhibitCharge: Bool = false { didSet { store(sleepInhibitCharge, "sleepInhibitCharge") } }
    @Published var exitInhibitCharge: Bool = false { didSet { store(exitInhibitCharge, "exitInhibitCharge") } }
    @Published var completelyDisableSleep: Bool = false { didSet { store(completelyDisableSleep, "completelyDisableSleep") } }
    @Published var displayOffWhenSleepDisabled: Bool = true { didSet { store(displayOffWhenSleepDisabled, "displayOffWhenSleepDisabled") } }
    @Published var lockScreenWhenClosed: Bool = false { didSet { store(lockScreenWhenClosed, "lockScreenWhenClosed") } }
    @Published var lpmPreference: Int = 0 { didSet { store(lpmPreference, "lpmPreference") } }
    @Published var dashboardBackgroundUpdates: Bool = false { didSet { store(dashboardBackgroundUpdates, "dashboardBackgroundUpdates") } }
    @Published var showProcessesInHighUsage: Bool = false { didSet { store(showProcessesInHighUsage, "showProcessesInHighUsage") } }
    @Published var energyThreshold: Int = 1 { didSet { store(energyThreshold, "appsSignificantEnergyThreshold") } }
    @Published var magsafeControl: Bool = true { didSet { store(magsafeControl, "magsafeControl"); applyMagSafe() } }
    @Published var magsafeOff: Bool = false { didSet { store(magsafeOff, "magsafeOff") } }
    @Published var magsafeBlinkDischarge: Bool = false { didSet { store(magsafeBlinkDischarge, "magsafeBlinkDischarge") } }
    @Published var colorMode: Int = 2 { didSet { store(colorMode, "colorMode"); syncTheme() } }
    @Published var showDockIcon: Bool = false { didSet { store(showDockIcon, "showDockIcon"); applyDockIcon() } }
    @Published var reduceTransparency: Bool = false { didSet { store(reduceTransparency, "reduceTransparency") } }
    @Published var launchAtLogin: Bool = false { didSet { store(launchAtLogin, "launchAtLogin"); applyLaunchAtLogin() } }
    @Published var showGUIonStartup: Bool = false { didSet { store(showGUIonStartup, "showGUIonStartup") } }
    @Published var showPercentage: Bool = true { didSet { store(showPercentage, "showPercentage") } }
    @Published var menuBarIconStyle: Int = 2 { didSet { store(menuBarIconStyle, "menuBarIconStyle") } }
    @Published var selectedMenuBarItems: Set<String> = [] { didSet { store(Array(selectedMenuBarItems), "selectedMenubarItemsList") } }
    @Published var menuBarSpacing: Int = 5 { didSet { store(menuBarSpacing, "menubarItemSpacing") } }
    @Published var startTasksAfterDue: Bool = false { didSet { store(startTasksAfterDue, "startTasksAfterDue") } }
    @Published var dataShareConsent: Bool = false { didSet { store(dataShareConsent, "dataShareConsent") } }
    @Published var checkForUpdates: Bool = true { didSet { store(checkForUpdates, "checkForUpdates") } }
    @Published var receiveBetaUpdates: Bool = false { didSet { store(receiveBetaUpdates, "receiveBetaUpdates") } }
    @Published var settingsLock: Bool = false { didSet { store(settingsLock, "settingsLock") } }
    @Published var lpmMenuBarColor: Bool = true { didSet { store(lpmMenuBarColor, "lpmMenuBarColor") } }
    @Published var systemIsDark: Bool = true { didSet { syncTheme() } }

    // MARK: - Private

    private let defaults = UserDefaults.standard
    private let sampler = PowerSampler()
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
    private var energyProcess: Process?

    // MARK: - Lifecycle

    var theme: Theme {
        colorMode == 0 ? Theme(isDark: systemIsDark) : Theme(isDark: colorMode == 2)
    }

    func syncTheme() {
        Theme.current = theme
    }

    private init() {
        loadSettings()
        systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        syncTheme()
        loadHistory()
        helperInstalled = HelperClient.shared.refreshInstallState()
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
    }

    private var powerTimer: Timer?

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

    private func pollLivePower() {
        let reading = meter.sample(fallback: snapshot)
        if reading.total > 0.01 || livePower.total == 0 {
            livePower = reading
        }
        flowTicker.update(flowModel)
    }

    private func tick() {
        tickCount += 1
        snapshot = BatteryReader.read()
        if tickCount % 3 == 0 {
            power = sampler.read()
        }
        refreshComponentPower()
        history.append(battery: Double(snapshot.percentage),
                       temperature: snapshot.temperature,
                       power: energyUseWatts,
                       capacity: Double(snapshot.healthPercent),
                       limit: chargeVal)
        if calibration != nil { advanceCalibration() } else { evaluateChargeControl() }
        updateChargeState()
        if tickCount % 10 == 0 { refreshEnergyApps() }
        if tickCount % 30 == 0 {
            helperInstalled = HelperClient.shared.refreshInstallState()
            saveHistory()
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
            statusNote = String(format: "电池温度 %.1f°C 超过上限 %d°C，充电已暂停", snapshot.temperature, maxTemperature)
            setCharging(false)
            return
        }
        if heatPause {
            if snapshot.temperature <= Double(maxTemperature) - 2 {
                heatPause = false
                statusNote = ""
                lastChargingAllowed = nil
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

    private func applyChargeLimitIfNeeded() {
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

    func topUp() {
        userPaused = false
        chargeVal = 100
        lastChargingAllowed = nil
        statusNote = ""
        log("充满", "充电限制已设为 100%")
    }

    func pauseCharging() {
        userPaused = true
        lastChargingAllowed = nil
        setCharging(false)
        statusNote = "充电已暂停"
    }

    func resumeCharging() {
        userPaused = false
        lastChargingAllowed = nil
        statusNote = ""
    }

    func applyMagSafe() {
        guard capabilities.canMagSafeLED else { return }
        let mode: MagSafeLED = !magsafeControl ? .system : (magsafeOff ? .off : .system)
        try? ChargeController.shared.setMagSafeLED(mode)
    }

    // MARK: - Calibration

    func startCalibration() {
        calibration = CalibrationRun(stage: .chargeToFull, startedAt: Date())
        lastAppliedLimit = nil
        chargeVal = 100
        statusNote = "校准已开始：正在充电至 100%"
        log("校准", "校准模式已启动")
    }

    func stopCalibration() {
        calibration = nil
        chargeVal = calibrationBackup
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        statusNote = "校准已取消"
        log("校准", "校准模式已取消")
    }

    private func advanceCalibration() {
        guard var run = calibration else { return }
        let soc = snapshot.percentage
        switch run.stage {
        case .chargeToFull:
            if soc >= 100 {
                run.stage = .dischargeToTen
                statusNote = "放电至 10%"
            }
        case .dischargeToTen:
            if soc <= 10 {
                run.stage = .chargeToFullAgain
                chargeVal = 100
                lastAppliedLimit = nil
                statusNote = "重新充电至 100%"
            } else {
                startDischargeInternal(to: 10)
            }
        case .chargeToFullAgain:
            if soc >= 100 {
                run.stage = .hold
                run.holdUntil = Date().addingTimeInterval(3600)
                statusNote = "保持满电 1 小时"
            }
        case .hold:
            if let until = run.holdUntil, Date() >= until {
                run.stage = .dischargeToLimit
                statusNote = "放电至 \(calibrationBackup)%"
            }
        case .dischargeToLimit:
            if soc <= calibrationBackup {
                calibration = nil
                chargeVal = calibrationBackup
                lastAppliedLimit = nil
                lastChargingAllowed = nil
                store(Date().timeIntervalSince1970, "lastCalibrationTimestamp")
                statusNote = "校准完成"
                log("校准", "校准完成，上次校准时间已更新")
                return
            }
            startDischargeInternal(to: calibrationBackup)
        }
        calibration = run
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
            statusNote = "仅连接充电器时才能设置放电"
            return
        }
        startDischargeInternal(to: target)
        statusNote = "放电至 \(target)%"
        log("放电", "开始放电至 \(target)%")
    }

    // MARK: - Scheduled tasks

    func checkScheduledTasks() {
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now) // 1 = Sunday
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        for index in tasks.indices {
            var task = tasks[index]
            guard task.enabled, task.weekdays.contains(isoWeekday) else { continue }
            guard task.hour == hour, abs(task.minute - minute) < 1 else { continue }
            if let last = task.lastRun, calendar.isDate(last, equalTo: now, toGranularity: .minute) { continue }
            run(task)
            task.lastRun = now
            tasks[index] = task
        }
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
            log("设置充电限制", "已设为 \(task.value)%")
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

    func refreshEnergyApps() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let output = shell("/bin/ps", ["-A", "-o", "pcpu=,comm="])
        var cpuByPath: [String: Double] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0]) else { continue }
            cpuByPath[String(parts[1])] = cpu
        }
        var result: [HighUsageApp] = []
        for app in running {
            guard let url = app.bundleURL else { continue }
            let cpu = cpuByPath[url.path] ?? 0
            guard cpu > 0.5 else { continue }
            result.append(HighUsageApp(bundleID: app.bundleIdentifier ?? url.lastPathComponent,
                                       name: app.localizedName ?? url.lastPathComponent,
                                       energyImpact: cpu,
                                       icon: app.icon))
        }
        highUsageApps = result.sorted { $0.energyImpact > $1.energyImpact }
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

    func installHelper() {
        do {
            try HelperClient.shared.install()
            helperInstalled = true
            capabilities = ChargeController.shared.detectCapabilities()
            capabilities.hasHelper = true
            lastMessage = "特权助手已安装"
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func removeHelper() {
        HelperClient.shared.uninstall()
        helperInstalled = false
        capabilities.hasHelper = false
        lastMessage = "特权助手已移除"
    }

    func refreshCapabilities() {
        capabilities = ChargeController.shared.detectCapabilities()
        capabilities.hasHelper = helperInstalled
    }

    // MARK: - Appearance / login item

    func applyDockIcon() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApp.activate(ignoringOtherApps: true) }
    }

    private func applyLaunchAtLogin() {
        let label = "com.aibattery.app"
        let path = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        if launchAtLogin {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>\(Bundle.main.bundlePath)/Contents/MacOS/AIBattery</string></array>
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
            .appendingPathComponent("AIBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    private func saveHistory() {
        struct Stored: Codable { var battery: [HistoryPoint]; var temperature: [HistoryPoint]; var power: [HistoryPoint]; var capacity: [HistoryPoint] }
        let stored = Stored(battery: history.battery.suffix(600).map { $0 },
                            temperature: history.temperature.suffix(600).map { $0 },
                            power: history.power.suffix(600).map { $0 },
                            capacity: history.capacity.suffix(600).map { $0 })
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: historyURL)
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
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        chargeVal = int("chargeVal", 80)
        allowBelow80 = bool("allowChargeLimitsBelow80", true)
        automaticDischarge = bool("automaticDischarge", true)
        sailingMode = bool("sailingMode", true)
        sailingLevel = int("sailingLevel", 5)
        heatProtectMode = bool("heatProtectMode", false)
        maxTemperature = int("maxTemperature", 35)
        calibrationBackup = int("calibrationBackupPercentage", 80)
        sleepMode = int("sleepMode", 0)
        sleepInhibitCharge = bool("sleepInhibitCharge", false)
        exitInhibitCharge = bool("exitInhibitCharge", false)
        completelyDisableSleep = bool("completelyDisableSleep", false)
        displayOffWhenSleepDisabled = bool("displayOffWhenSleepDisabled", true)
        lockScreenWhenClosed = bool("lockScreenWhenClosed", false)
        lpmPreference = int("lpmPreference", 0)
        dashboardBackgroundUpdates = bool("dashboardBackgroundUpdates", false)
        showProcessesInHighUsage = bool("showProcessesInHighUsage", false)
        energyThreshold = int("appsSignificantEnergyThreshold", 1)
        magsafeControl = bool("magsafeControl", true)
        magsafeOff = bool("magsafeOff", false)
        magsafeBlinkDischarge = bool("magsafeBlinkDischarge", false)
        colorMode = int("colorMode", 2)
        showDockIcon = bool("showDockIcon", false)
        reduceTransparency = bool("reduceTransparency", false)
        launchAtLogin = bool("launchAtLogin", false)
        showGUIonStartup = bool("showGUIonStartup", true)
        showPercentage = bool("showPercentage", true)
        menuBarIconStyle = int("menuBarIconStyle", 2)
        menuBarSpacing = int("menubarItemSpacing", 5)
        startTasksAfterDue = bool("startTasksAfterDue", false)
        dataShareConsent = bool("dataShareConsent", false)
        checkForUpdates = bool("checkForUpdates", true)
        receiveBetaUpdates = bool("receiveBetaUpdates", false)
        settingsLock = bool("settingsLock", false)
        lpmMenuBarColor = bool("lpmMenuBarColor", true)
        if let list = defaults.array(forKey: "selectedMenubarItemsList") as? [String] {
            selectedMenuBarItems = Set(list)
        }
        if let data = defaults.data(forKey: "scheduledTasks"),
           let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            tasks = decoded
        }
        if let data = defaults.data(forKey: "taskHistory"),
           let decoded = try? JSONDecoder().decode([TaskLogEntry].self, from: data) {
            taskHistory = decoded
        }
    }

    // MARK: - Derived values

    var limitMarkerFraction: Double { Double(chargeVal) / 100.0 }

    var stateExplanation: String {
        switch chargeState {
        case .charging:
            return "正在充电，当前 \(snapshot.percentage)%，充电限制 \(chargeVal)%。达到限制后充电会自动暂停。"
        case .paused:
            return "充电已暂停，当电池电量达到 \(max(0, chargeVal - sailingLevel))% 时将自动恢复。您的 MacBook 通过电源适配器供电。电池通常处于旁路状态，仅在系统负载较重时提供电力。您的 MacBook 将正常进入睡眠状态，并保持在 \(chargeVal)% 的电量水平。"
        case .discharging:
            return "正在放电至 \(chargeVal)%。在此期间 MacBook 会使用电池供电，达到目标后恢复充电。"
        case .full:
            return "电池已充满，正在使用电源适配器供电。"
        case .calibrating:
            return "校准模式进行中：\(calibration?.stage.title ?? "")。请保持电源适配器连接。"
        case .noAdapter:
            return "未连接电源适配器，正在使用电池供电。"
        case .noBattery:
            return "未检测到电池。"
        }
    }

    var flowModel: PowerFlowModel {
        let socReading: PowerReading = power.soc.map { .measured($0) } ?? soc
        let displayReading: PowerReading = power.display.map { .measured($0) } ?? displayPower
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
    private func refreshComponentPower() {
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

    var adapterPower: Double { snapshot.systemPowerIn }
    var macbookPower: Double { snapshot.systemLoad }
    var batteryPowerAbs: Double { abs(snapshot.batteryPower) }
}
