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
    case calibration
    case fanControl
    case sleep
    case schedule
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "仪表板"
        case .chargeControl: return "充电控制"
        case .calibration: return "电池校准"
        case .fanControl: return "风扇控制"
        case .sleep: return "睡眠与能源"
        case .schedule: return "定时设置"
        case .other: return "其他"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .chargeControl: return "battery.75"
        case .calibration: return "wrench.and.screwdriver"
        case .fanControl: return "fanblades"
        case .sleep: return "moon"
        case .schedule: return "calendar.badge.clock"
        case .other: return "shippingbox"
        }
    }

    var category: String? {
        switch self {
        case .dashboard: return nil
        case .chargeControl, .calibration, .fanControl, .sleep: return "电池保养"
        case .schedule: return "自动化"
        case .other: return "外观"
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
    @Published var colorMode: Int = 2 { didSet { store(colorMode, "colorMode"); syncTheme() } }
    @Published var launchAtLogin: Bool = false { didSet { store(launchAtLogin, "launchAtLogin"); applyLaunchAtLogin() } }
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


    // MARK: - Lifecycle

    var theme: Theme {
        colorMode == 0 ? Theme(isDark: systemIsDark) : Theme(isDark: colorMode == 2)
    }

    func syncTheme() {
        Theme.current = theme
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
        refreshComponentPower()
        history.append(battery: Double(snapshot.percentage),
                       temperature: snapshot.temperature,
                       power: energyUseWatts,
                       capacity: Double(snapshot.healthPercent),
                       limit: chargeVal)
        // A running calibration owns the charge hardware; the normal limit loop
        // must stay out of its way until the session ends.
        if calibrationEngine.isRunning {
            mirrorCalibration()
        } else {
            if calibration != nil { endCalibrationMirror() }
            evaluateChargeControl()
        }
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


    // MARK: - Calibration
    //
    // The session itself lives in CalibrationEngine (1 Hz measurement, phase
    // machine, SMC control). AppState keeps a coarse mirror so the dashboard
    // card and the charge-state pill stay correct, and restores the user's
    // charge limit when the session ends.

    private var calibrationEngine: CalibrationEngine { CalibrationEngine.shared }

    func startCalibration() {
        guard !calibrationEngine.isRunning else { return }
        calibration = CalibrationRun(stage: .chargeToFull, startedAt: Date())
        lastAppliedLimit = nil
        chargeVal = 100
        statusNote = "校准已开始：正在充电至 100%"
        calibrationEngine.start()
        log("校准", "校准模式已启动")
    }

    func stopCalibration() {
        calibrationEngine.stop()
        calibration = nil
        chargeVal = calibrationBackup
        lastAppliedLimit = nil
        lastChargingAllowed = nil
        statusNote = "校准已取消"
        log("校准", "校准模式已取消")
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
        statusNote = finished ? "校准完成" : "校准已取消"
        log("校准", statusNote)
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
            lastMessage = "特权助手已安装"
        } catch {
            lastMessage = error.localizedDescription
        }
    }



    // MARK: - Appearance / login item

    private func applyLaunchAtLogin() {
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
        colorMode = int("colorMode", 2)
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
}
