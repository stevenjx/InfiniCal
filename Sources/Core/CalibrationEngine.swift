//
//  CalibrationEngine.swift
//  The calibration state machine: measure, control, decide, record.
//
//  A run walks the pack through one complete cycle — charge to 100 %, discharge
//  under a controlled load to the target, recharge to 100 %, rest, then settle
//  back to the storage level — while integrating current over time. The charge
//  moved in each direction is what turns into a real capacity and a real state
//  of health, instead of the single firmware estimate macOS shows.
//
//  Everything is driven from InfiniCal's own telemetry (IORegistry + SMC) and
//  its own privileged helper. No third-party app is involved at any step.
//

import Foundation
import AppKit
import Darwin
import IOKit.pwr_mgt
import UserNotifications

// MARK: - Phases

enum CalibrationPhase: String {
    case idle
    case chargingToFull
    case discharging
    case rechargingToFull
    case holdingAtFull
    case dischargingToBuffer
    case completed

    var title: String {
        switch self {
        case .idle: return t("就绪")
        case .chargingToFull: return t("预充至 100%")
        case .discharging: return t("受控放电")
        case .rechargingToFull: return t("复充至 100%")
        case .holdingAtFull: return t("满电静置")
        case .dischargingToBuffer: return t("回落至存储电量")
        case .completed: return t("已完成")
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "pause.circle.fill"
        case .chargingToFull: return "bolt.fill"
        case .discharging: return "arrow.down.to.line"
        case .rechargingToFull: return "bolt.badge.clock.fill"
        case .holdingAtFull: return "hourglass"
        case .dischargingToBuffer: return "battery.75"
        case .completed: return "checkmark.circle.fill"
        }
    }

    /// Mirror onto the coarse stages the dashboard card already understands.
    var stage: CalibrationStage? {
        switch self {
        case .idle: return nil
        case .chargingToFull: return .chargeToFull
        case .discharging: return .dischargeToTen
        case .rechargingToFull: return .chargeToFullAgain
        case .holdingAtFull: return .hold
        case .dischargingToBuffer: return .dischargeToLimit
        case .completed: return nil
        }
    }
}

enum DischargeStressMode: String, CaseIterable, Identifiable {
    case silent
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent: return t("静音")
        case .balanced: return t("均衡")
        case .aggressive: return t("性能")
        }
    }

    var detail: String {
        switch self {
        case .silent: return t("不施加负载，仅靠系统自身耗电放电")
        case .balanced: return t("约一半核心参与负载")
        case .aggressive: return t("除一个核心外全部参与负载")
        }
    }

    func workerCount(cores: Int) -> Int {
        switch self {
        case .silent: return 0
        case .balanced: return max(1, cores / 2)
        case .aggressive: return max(1, cores - 1)
        }
    }

    var sleepMicroseconds: UInt32 {
        switch self {
        case .silent: return 0
        case .balanced: return 2000
        case .aggressive: return 100
        }
    }
}

// MARK: - Engine

final class CalibrationEngine: ObservableObject {

    static let shared = CalibrationEngine()

    // MARK: Live telemetry (1 Hz)

    @Published var phase: CalibrationPhase = .idle
    @Published var percentage: Int = 0
    @Published var voltage: Double = 0
    @Published var signedAmperage: Double = 0
    @Published var batteryPower: Double = 0
    @Published var temperature: Double = 0
    @Published var designCapacityMAh: Double = 0
    @Published var rawMaxCapacityMAh: Double = 0
    @Published var remainingCapacityMAh: Double = 0
    @Published var cycleCount: Int = 0
    @Published var hardwareModel: String = "--"
    @Published var batterySerial: String = "--"
    @Published var cellVoltages: [Double] = []
    @Published var cellDeltaMillivolts: Double = 0
    @Published var isCharging: Bool = false
    @Published var isExternalConnected: Bool = false
    @Published var isDischargingOnAC: Bool = false

    // MARK: Host telemetry

    @Published var cpuPowerWatts: Double = 0
    @Published var cpuTemperature: Double = 0
    @Published var internalResistanceMilliohm: Double = 0

    // MARK: Session measurements

    @Published var dischargeEnergyWh: Double = 0
    @Published var dischargeEnergyAh: Double = 0
    @Published var rechargeEnergyWh: Double = 0
    @Published var rechargeEnergyAh: Double = 0
    @Published var coulombicEfficiency: Double = 0
    @Published var measuredCapacityWh: Double = 0
    @Published var measuredCapacityMAh: Double = 0
    @Published var measuredHealth: Double = 0
    @Published var dischargeElapsedSeconds: TimeInterval = 0
    @Published var dischargeAveragePower: Double = 0
    @Published var finalDischargeDurationText: String = "--"
    @Published var estimatedRemainingMinutes: Int = 0
    @Published var totalDischargeRuntimeMinutes: Int = 0
    @Published var isThermalCutoffActive: Bool = false

    // MARK: Estimates

    @Published var aiRemainingMinutes: Int = 0
    @Published var aiRemainingMAh: Double = 0
    @Published var aiTrueCapacityMAh: Double = 0
    @Published var aiTrueHealthPercent: Double = 0
    @Published var aiConfidence: Double = 0
    @Published var aggregated: AggregatedHealth?

    // MARK: Charts & log

    @Published var chartPoints: [CalibrationSample] = []
    @Published var dischargeCurve: [CalibrationSample] = []
    @Published var log: [String] = []
    @Published var lastReportURL: URL?
    @Published var lastCSVURL: URL?

    // MARK: History

    @Published var records: [CalibrationRecord] = []
    @Published var lastCalibrationDate: Date?

    // MARK: Settings (persisted)

    @Published var stressMode: DischargeStressMode = .balanced {
        didSet {
            UserDefaults.standard.set(stressMode.rawValue, forKey: Keys.stressMode)
            if isRunning, phase == .discharging { startStressLoad() }
        }
    }
    @Published var dischargeTarget: Int = 10 {
        didSet { UserDefaults.standard.set(dischargeTarget, forKey: Keys.dischargeTarget) }
    }
    @Published var highTemperature: Double = 45 {
        didSet { UserDefaults.standard.set(highTemperature, forKey: Keys.highTemperature) }
    }
    @Published var resumeTemperature: Double = 39 {
        didSet { UserDefaults.standard.set(resumeTemperature, forKey: Keys.resumeTemperature) }
    }
    @Published var autoExport: Bool = true {
        didSet { UserDefaults.standard.set(autoExport, forKey: Keys.autoExport) }
    }
    @Published var soundAlert: Bool = true {
        didSet { UserDefaults.standard.set(soundAlert, forKey: Keys.soundAlert) }
    }

    // MARK: Private state

    private enum Keys {
        static let stressMode = "calibrationStressMode"
        static let dischargeTarget = "calibrationDischargeTarget"
        static let highTemperature = "calibrationHighTemperature"
        static let resumeTemperature = "calibrationResumeTemperature"
        static let autoExport = "calibrationAutoExport"
        static let soundAlert = "calibrationSoundAlert"
        static let lastRun = "lastCalibrationTimestamp"
        static let backupLevel = "calibrationBackupPercentage"
    }

    private let defaults = UserDefaults.standard
    private let integrator = CoulombIntegrator()
    private let dcir = DCIRCalculator()
    private let model = BatteryHealthModel()

    private var timer: Timer?
    private var telemetryPageUsers = 0
    private var rawPoints: [CalibrationSample] = []
    private var sessionPoints: [CalibrationSample] = []
    private var downsampleCounter = 0
    private var stressTasks: [Task<Void, Never>] = []
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false
    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    private var sessionStart: Date?
    private var dischargeStart: Date?
    private var holdStart: Date?
    @Published var dischargeStartPercentage = 100
    private var sessionReportURL: URL?
    private var sessionCSVURL: URL?

    private let holdDurationSeconds: TimeInterval = 600

    private(set) var isRunning = false

    var storageLevel: Int {
        let stored = defaults.integer(forKey: Keys.backupLevel)
        return stored > 0 ? stored : 80
    }

    // MARK: - Lifecycle

    private init() {
        if let raw = defaults.string(forKey: Keys.stressMode),
           let mode = DischargeStressMode(rawValue: raw) {
            stressMode = mode
        }
        let target = defaults.integer(forKey: Keys.dischargeTarget)
        dischargeTarget = target > 0 ? target : 10
        let high = defaults.double(forKey: Keys.highTemperature)
        highTemperature = high > 0 ? high : 45
        let resume = defaults.double(forKey: Keys.resumeTemperature)
        resumeTemperature = resume > 0 ? resume : 39
        if defaults.object(forKey: Keys.autoExport) != nil {
            autoExport = defaults.bool(forKey: Keys.autoExport)
        }
        if defaults.object(forKey: Keys.soundAlert) != nil {
            soundAlert = defaults.bool(forKey: Keys.soundAlert)
        }

        hardwareModel = Self.machineModel()
        records = CalibrationStore.load()
        aggregated = CalibrationStore.aggregate(records)
        refreshLastRunDate()
        refreshNotificationPermission()

        // Telemetry is demand-driven: the calibration page owns the engine's
        // timer. This avoids a permanent 1 Hz SMC/CPU loop when the page is not
        // visible and no session is running.
        if isRunning {
            ensureTelemetryTimer()
        }
    }

    deinit {
        timer?.invalidate()
        for task in stressTasks { task.cancel() }
        if assertionActive { IOPMAssertionRelease(assertionID) }
    }

    func beginTelemetryPage() {
        telemetryPageUsers += 1
        ensureTelemetryTimer()
    }

    func endTelemetryPage() {
        telemetryPageUsers = max(0, telemetryPageUsers - 1)
        if telemetryPageUsers == 0 && !isRunning {
            timer?.invalidate()
            timer = nil
        }
    }

    private func ensureTelemetryTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Session control

    func start() {
        guard !isRunning else { return }

        isRunning = true
        ensureTelemetryTimer()
        sessionStart = Date()
        holdStart = nil
        dischargeStartPercentage = percentage
        sessionReportURL = nil
        sessionCSVURL = nil
        lastReportURL = nil
        lastCSVURL = nil

        integrator.reset()
        dcir.reset()
        dischargeEnergyWh = 0
        dischargeEnergyAh = 0
        rechargeEnergyWh = 0
        rechargeEnergyAh = 0
        coulombicEfficiency = 0
        measuredCapacityWh = 0
        measuredCapacityMAh = 0
        measuredHealth = 0
        dischargeElapsedSeconds = 0
        dischargeAveragePower = 0
        finalDischargeDurationText = "--"
        estimatedRemainingMinutes = 0
        totalDischargeRuntimeMinutes = 0
        internalResistanceMilliohm = 0
        isThermalCutoffActive = false
        sessionPoints.removeAll()
        dischargeCurve.removeAll()

        enableSleepBlock()
        append(t(">>> 开始电池校准 <<<"))
        if !isExternalConnected {
            append(t("未连接电源适配器：请接入电源，否则无法完成预充与复充阶段"))
        }

        if signedAmperage < -0.05 || isDischargingOnAC {
            phase = .discharging
            dischargeStartPercentage = percentage
            dischargeStart = Date()
            dischargeCurve.removeAll()
            append(t("电池已在放电，直接进入受控放电阶段"))
            startStressLoad()
            holdDischarge(to: dischargeTarget)
        } else {
            phase = .chargingToFull
            dischargeStart = nil
            append(t("等待电池充满至 100%…"))
            stopStressLoad()
            releaseDischarge()
        }
    }

    func stop(reason: String? = nil) {
        guard isRunning else { return }
        stopStressLoad()
        releaseDischarge(limit: storageLevel)
        disableSleepBlock()
        isRunning = false
        holdStart = nil
        phase = .idle
        append(reason ?? t("用户中止了校准"))
        if telemetryPageUsers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Quit path: a session must never leave the pack blocked or the sleep
    /// assertion held once the process is gone.
    func prepareForTermination() {
        guard isRunning else { return }
        stopStressLoad()
        releaseDischarge(limit: storageLevel)
        disableSleepBlock()
        isRunning = false
        phase = .idle
    }

    // MARK: - Tick

    private func tick() {
        let phase = self.phase
        if phase == .idle && !isRunning && telemetryPageUsers == 0 {
            return
        }

        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let snapshot = BatteryReader.read()
        apply(snapshot)

        let cpuRatio = cpuUsageRatio()
        let smoothedPower = model.smoothPower(batteryPower)
        refreshThermal(smoothedPower: smoothedPower, cpuRatio: cpuRatio)

        if let resistance = dcir.feed(uptime: uptime, currentAmps: signedAmperage, voltageVolts: voltage) {
            internalResistanceMilliohm = resistance
        }

        let point = CalibrationSample(timestamp: now,
                                      percentage: Double(percentage),
                                      power: batteryPower,
                                      voltage: voltage,
                                      amperage: signedAmperage,
                                      temperature: temperature)
        appendChartPoint(point)
        updateEstimates(smoothedPower: smoothedPower)

        guard isRunning else { return }

        sessionPoints.append(point)
        if sessionPoints.count > 120_000 { sessionPoints.removeFirst(20_000) }

        handleThermalCutoff()
        let totals = integrator.step(uptime: uptime,
                                     currentSignedAmps: signedAmperage,
                                     voltageVolts: voltage)
        advance(totals: totals, now: now)
    }

    private func apply(_ snapshot: BatterySnapshot) {
        percentage = snapshot.percentage
        voltage = snapshot.voltage
        let instant = snapshot.instantAmperage
        signedAmperage = abs(instant) >= 0.02 ? instant : snapshot.amperage
        batteryPower = voltage * abs(signedAmperage)
        temperature = snapshot.temperature
        designCapacityMAh = Double(snapshot.designCapacity)
        rawMaxCapacityMAh = Double(snapshot.maxCapacity)
        remainingCapacityMAh = Double(snapshot.currentCapacity)
        cycleCount = snapshot.cycleCount
        isExternalConnected = snapshot.isPluggedIn
        isCharging = snapshot.isCharging
        isDischargingOnAC = snapshot.isPluggedIn && signedAmperage < -0.05
        cellVoltages = snapshot.cellVoltages
        if let low = snapshot.cellVoltages.min(), let high = snapshot.cellVoltages.max() {
            cellDeltaMillivolts = (high - low) * 1000
        } else {
            cellDeltaMillivolts = 0
        }
        if !snapshot.batterySerial.isEmpty { batterySerial = snapshot.batterySerial }
    }

    private func updateEstimates(smoothedPower: Double) {
        let fallbackCap = rawMaxCapacityMAh > 500 ? rawMaxCapacityMAh : max(designCapacityMAh * 0.93, 1)
        let estimate = model.inferTrueHealth(records: records,
                                             designCapacityMAh: designCapacityMAh,
                                             hardwareMaxCapacityMAh: fallbackCap)
        aiTrueCapacityMAh = estimate.capacityMAh
        aiTrueHealthPercent = estimate.healthPercent
        aiConfidence = estimate.confidence
        aiRemainingMAh = estimate.capacityMAh * Double(percentage) / 100

        if signedAmperage < -0.05 || isDischargingOnAC {
            aiRemainingMinutes = model.remainingMinutes(percentage: percentage,
                                                        voltage: voltage,
                                                        power: smoothedPower,
                                                        fullCapacityMAh: estimate.capacityMAh)
        } else {
            aiRemainingMinutes = 0
        }
    }

    // MARK: - Phase machine

    private func advance(totals: CoulombTotals, now: Date) {
        switch phase {
        case .chargingToFull:
            let startedDischarging = signedAmperage < -0.05 || isDischargingOnAC
            let fullAndIdle = percentage >= 100 && signedAmperage <= 0.05
            if startedDischarging || fullAndIdle { beginDischargePhase() }

        case .discharging:
            dischargeEnergyWh = totals.dischargeWh
            dischargeEnergyAh = totals.dischargeAh
            updateDischargeDerived(now: now)
            if percentage <= dischargeTarget { endDischargePhase() }

        case .rechargingToFull:
            rechargeEnergyWh = totals.rechargeWh
            rechargeEnergyAh = totals.rechargeAh
            if dischargeEnergyAh > 0, rechargeEnergyAh > 0 {
                coulombicEfficiency = dischargeEnergyAh / rechargeEnergyAh * 100
            }
            if percentage >= 100 && signedAmperage < 0.15 { beginHoldPhase() }

        case .holdingAtFull:
            if let start = holdStart, now.timeIntervalSince(start) >= holdDurationSeconds {
                beginStorageDrop()
            }

        case .dischargingToBuffer:
            if percentage <= storageLevel { finish() }

        case .idle, .completed:
            break
        }
    }

    private func updateDischargeDerived(now: Date) {
        guard let start = dischargeStart else { return }
        let elapsed = now.timeIntervalSince(start)
        dischargeElapsedSeconds = elapsed

        if elapsed > 10 {
            dischargeAveragePower = dischargeEnergyWh / (elapsed / 3600)
        } else {
            dischargeAveragePower = batteryPower
        }

        let deltaFraction = Double(dischargeStartPercentage - percentage) / 100
        guard deltaFraction >= 0.01 else { return }

        measuredCapacityWh = dischargeEnergyWh / deltaFraction
        measuredCapacityMAh = dischargeEnergyAh / deltaFraction * 1000
        if designCapacityMAh > 0 {
            measuredHealth = measuredCapacityMAh / designCapacityMAh * 100
        }

        let percentDropped = Double(dischargeStartPercentage - percentage)
        if percentDropped > 0, elapsed > 10 {
            let secondsPerPercent = elapsed / percentDropped
            let percentRemaining = max(0, Double(percentage - dischargeTarget))
            estimatedRemainingMinutes = Int(percentRemaining * secondsPerPercent / 60)
            let span = max(10, Double(dischargeStartPercentage - dischargeTarget))
            totalDischargeRuntimeMinutes = Int(span * secondsPerPercent / 60)
        }
    }

    private func beginDischargePhase() {
        phase = .discharging
        dischargeStartPercentage = percentage
        dischargeStart = Date()
        dischargeCurve.removeAll()
        dischargeCurve.append(CalibrationSample(timestamp: Date(),
                                                percentage: Double(percentage),
                                                power: batteryPower,
                                                voltage: voltage,
                                                amperage: signedAmperage,
                                                temperature: temperature))
        append(tf("预充完成，转入受控放电阶段（{p}%）[{p}]", "\(percentage)", stressMode.title))
        notify(t("预充完成"), tf("电池已充至 {p}%，开始受控放电校准。", "\(percentage)"))
        startStressLoad()
        holdDischarge(to: dischargeTarget)
    }

    private func endDischargePhase() {
        let hours = Int(dischargeElapsedSeconds) / 3600
        let minutes = (Int(dischargeElapsedSeconds) % 3600) / 60
        finalDischargeDurationText = tf("{p} 小时 {p} 分（平均 {p} W）", "\(hours)", "\(minutes)", String(format: "%.1f", dischargeAveragePower))
        append(tf("放电完成（{p}%），耗时 {p} 小时 {p} 分，平均放电功率 {p} W", "\(dischargeTarget)", "\(hours)", "\(minutes)", String(format: "%.2f", dischargeAveragePower)))

        stopStressLoad()
        releaseDischarge(limit: 100)
        phase = .rechargingToFull
        notify(t("放电完成"), t("电量已放至目标值，请保持电源连接以完成满电复充。"))
    }

    private func beginHoldPhase() {
        phase = .holdingAtFull
        holdStart = Date()
        append(t("电池已充满，进入 10 分钟满电静置"))
        notify(t("满电静置"), t("电池已充至 100%，正在静置以消除极化。"))
    }

    private func beginStorageDrop() {
        append(tf("静置完成，开始回落至 {p}% 存储电量", "\(storageLevel)"))
        phase = .dischargingToBuffer
        holdDischarge(to: storageLevel)
        notify(t("回落至存储电量"), tf("校准即将完成，正在缓慢放电至 {p}% 存储电量。", "\(storageLevel)"))
    }

    private func finish() {
        stopStressLoad()
        releaseDischarge(limit: storageLevel)
        disableSleepBlock()
        isRunning = false
        holdStart = nil
        phase = .completed

        append("==========================================")
        append(t("          电池校准圆满完成          "))
        append(tf("总放电耗时: {p}", finalDischargeDurationText))
        append(tf("放电能耗: {p} Wh | 复充能耗: {p} Wh", String(format: "%.2f", dischargeEnergyWh), String(format: "%.2f", rechargeEnergyWh)))
        append(tf("实测容量: {p} Wh ({p} mAh)", String(format: "%.2f", measuredCapacityWh), String(format: "%.0f", measuredCapacityMAh)))
        append(tf("健康度: {p}", designCapacityMAh > 0 ? String(format: "%.1f%%", measuredHealth) : "--"))
        append(tf("库仑效率: {p}", rechargeEnergyAh > 0 ? String(format: "%.1f%%", coulombicEfficiency) : "--"))
        append(tf("直流内阻 (DCIR): {p}", internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--"))
        append("==========================================")

        let record = CalibrationRecord(startDate: sessionStart ?? Date(),
                                       endDate: Date(),
                                       startDischargePercentage: dischargeStartPercentage,
                                       cycleCount: cycleCount,
                                       designCapacityMAh: designCapacityMAh,
                                       calculatedCapacityMAh: measuredCapacityMAh,
                                       calculatedCapacityWh: measuredCapacityWh,
                                       batteryHealthPercentage: measuredHealth,
                                       dischargeEnergyWh: dischargeEnergyWh,
                                       dischargeEnergyAh: dischargeEnergyAh,
                                       rechargeEnergyWh: rechargeEnergyWh,
                                       rechargeEnergyAh: rechargeEnergyAh,
                                       coulombicEfficiency: coulombicEfficiency,
                                       internalResistanceMilliohm: internalResistanceMilliohm)

        if autoExport {
            exportReports(record: record)
        }
        records = CalibrationStore.append(record)
        aggregated = CalibrationStore.aggregate(records)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastRun)
        refreshLastRunDate()
        notify(t("校准完成"), tf("真实容量 {p} mAh，健康度 {p}。", String(format: "%.0f", measuredCapacityMAh), String(format: "%.1f%%", measuredHealth)))
    }

    // MARK: - Hardware control (own helper, no external app)

    /// Discharge on AC: either drop the charge ceiling to the target (BCLM makes
    /// the pack drain to it) or inhibit charging outright on Intel/T2.
    private func holdDischarge(to target: Int) {
        let controller = ChargeController.shared
        switch controller.capabilities.strategy {
        case .bclm:
            do { try controller.applyChargeLimit(target) } catch {
                append(tf("SMC: 写入放电上限失败 — {p}", error.localizedDescription))
            }
        case .ch0bch0c, .chie:
            do { try controller.setChargingAllowed(false) } catch {
                append(tf("SMC: 阻断充电失败 — {p}", error.localizedDescription))
            }
        case .unavailable:
            append(t("SMC: 此机型未暴露充电控制键，无法在接电时强制放电"))
        }
    }

    private func releaseDischarge(limit: Int = 100) {
        let controller = ChargeController.shared
        switch controller.capabilities.strategy {
        case .bclm:
            try? controller.applyChargeLimit(limit)
        case .ch0bch0c, .chie:
            try? controller.setChargingAllowed(true)
        case .unavailable:
            break
        }
    }

    // MARK: - Stress load

    private func startStressLoad() {
        stopStressLoad()
        guard !isThermalCutoffActive, stressMode != .silent else { return }

        let workers = stressMode.workerCount(cores: ProcessInfo.processInfo.activeProcessorCount)
        let sleepMicros = stressMode.sleepMicroseconds
        for _ in 0..<workers {
            let task = Task.detached(priority: .userInitiated) {
                var value: Double = 1
                while !Task.isCancelled {
                    for _ in 0..<10_000 {
                        value = sin(value) * cos(value) + tan(0.12345)
                    }
                    usleep(sleepMicros)
                }
            }
            stressTasks.append(task)
        }
        append(tf("放电负载已启动 [{p}]: {p} 个工作线程", stressMode.title, "\(workers)"))
    }

    private func stopStressLoad() {
        guard !stressTasks.isEmpty else { return }
        for task in stressTasks { task.cancel() }
        stressTasks.removeAll()
        append(t("已停止放电负载"))
    }

    // MARK: - Thermal protection

    private func handleThermalCutoff() {
        guard phase == .discharging else { return }
        let resumeLine = min(resumeTemperature, highTemperature - 1)

        if temperature >= highTemperature, !isThermalCutoffActive {
            isThermalCutoffActive = true
            stopStressLoad()
            append(tf("过热保护: {p}°C ≥ 阈值 {p}°C，已暂停负载", String(format: "%.1f", temperature), "\(Int(highTemperature))"))
            notify(t("过热保护已触发"), tf("电池温度已达 {p}°C，放电负载已暂停等待降温。", String(format: "%.1f", temperature)))
        } else if temperature <= resumeLine, isThermalCutoffActive {
            isThermalCutoffActive = false
            startStressLoad()
            append(tf("温度恢复: {p}°C ≤ 恢复线 {p}°C，已恢复负载", String(format: "%.1f", temperature), "\(Int(resumeLine))"))
        }
    }

    // MARK: - Host telemetry

    private func refreshThermal(smoothedPower: Double, cpuRatio: Double) {
        if let cpu = hidCPUTemperature(), cpu > 10, cpu < 115 {
            cpuTemperature = cpu
        } else if cpuTemperature <= 0 {
            for key in ["TC0P", "TC0D", "TC0E"] {
                if let value = try? SMC.shared.readDouble(key), value > 10, value < 115 {
                    cpuTemperature = value
                    break
                }
            }
        }

        if signedAmperage < -0.05 || isDischargingOnAC {
            cpuPowerWatts = max(0.8, smoothedPower * 0.55)
        } else {
            cpuPowerWatts = max(1.2, cpuRatio * 45)
        }
    }

    private func cpuUsageRatio() -> Double {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var processors: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &processors, &info, &count)
        guard result == KERN_SUCCESS, let info else { return 0.05 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(count * UInt32(MemoryLayout<integer_t>.stride)))
        }

        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
        let loads = info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(processors)) { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: Int(processors)))
        }
        for cpu in loads {
            user += cpu.cpu_ticks.0
            system += cpu.cpu_ticks.1
            idle += cpu.cpu_ticks.2
            nice += cpu.cpu_ticks.3
        }

        guard let previous = previousCPUTicks else {
            previousCPUTicks = (user, system, idle, nice)
            return 0.08
        }
        // 32-bit tick counters wrap; &- keeps that from trapping.
        let deltaUser = Double(user &- previous.user)
        let deltaSystem = Double(system &- previous.system)
        let deltaIdle = Double(idle &- previous.idle)
        let deltaNice = Double(nice &- previous.nice)
        previousCPUTicks = (user, system, idle, nice)

        let total = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard total > 0 else { return 0.05 }
        return min(1, max(0.01, (deltaUser + deltaSystem + deltaNice) / total))
    }

    /// CPU die temperature from the HID sensor page — works on Intel and Apple
    /// Silicon, and needs no privileges.
    private func hidCPUTemperature() -> Double? {
        typealias CreateFunc = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias MatchFunc = @convention(c) (AnyObject, CFDictionary) -> Void
        typealias ServicesFunc = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
        typealias PropertyFunc = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
        typealias EventFunc = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
        typealias FloatFunc = @convention(c) (AnyObject, UInt32) -> Double

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }

        let create = unsafeBitCast(createSym, to: CreateFunc.self)
        let match = unsafeBitCast(matchSym, to: MatchFunc.self)
        let copyServices = unsafeBitCast(servicesSym, to: ServicesFunc.self)
        let copyProperty = unsafeBitCast(propertySym, to: PropertyFunc.self)
        let copyEvent = unsafeBitCast(eventSym, to: EventFunc.self)
        let floatValue = unsafeBitCast(floatSym, to: FloatFunc.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }

        var readings: [Double] = []
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            let lower = name.lowercased()
            let isCPU = lower.contains("cpu") || lower.contains("pcore") || lower.contains("ecore")
                || lower.contains("die") || lower.contains("soc")
            guard isCPU else { continue }
            guard let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, 0x000F0000)
            if celsius > 15, celsius < 110 { readings.append(celsius) }
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    // MARK: - Sleep block

    private func enableSleepBlock() {
        guard !assertionActive else { return }
        let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "InfiniCal Calibration" as CFString,
                                                  &assertionID)
        if created == kIOReturnSuccess {
            assertionActive = true
            append(t("已阻止系统空闲睡眠，保证采样连续"))
        }
    }

    private func disableSleepBlock() {
        guard assertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionActive = false
        append(t("已恢复系统睡眠策略"))
    }

    // MARK: - Notifications

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                    content: content,
                                                                    trigger: nil))
        if soundAlert { NSSound.beep() }
    }

    // MARK: - Charts

    private func appendChartPoint(_ point: CalibrationSample) {
        rawPoints.append(point)
        if rawPoints.count > 3600 { rawPoints.removeFirst(rawPoints.count - 3600) }

        downsampleCounter += 1
        guard downsampleCounter >= 4 || chartPoints.isEmpty else { return }
        downsampleCounter = 0
        chartPoints = Self.downsample(rawPoints)

        if phase == .discharging {
            dischargeCurve.append(point)
            if dischargeCurve.count > 2400 {
                dischargeCurve = Self.decimate(dischargeCurve)
            }
        }
    }

    private static func downsample(_ points: [CalibrationSample]) -> [CalibrationSample] {
        let bucket = 8
        guard points.count > bucket else { return points }
        var result: [CalibrationSample] = []
        result.reserveCapacity(points.count / bucket + 1)
        var index = 0
        while index < points.count {
            let end = min(index + bucket, points.count)
            let slice = points[index..<end]
            let count = Double(slice.count)
            result.append(CalibrationSample(
                timestamp: slice.last?.timestamp ?? Date(),
                percentage: slice.reduce(0) { $0 + $1.percentage } / count,
                power: slice.reduce(0) { $0 + $1.power } / count,
                voltage: slice.reduce(0) { $0 + $1.voltage } / count,
                amperage: slice.reduce(0) { $0 + $1.amperage } / count,
                temperature: slice.reduce(0) { $0 + $1.temperature } / count
            ))
            index = end
        }
        return result
    }

    private static func decimate(_ points: [CalibrationSample]) -> [CalibrationSample] {
        var result: [CalibrationSample] = []
        result.reserveCapacity(points.count / 2 + 2)
        for (index, point) in points.enumerated() where index % 2 == 0 {
            result.append(point)
        }
        if let last = points.last { result.append(last) }
        return result
    }

    // MARK: - Reports

    private func exportReports(record: CalibrationRecord) {
        let stamp = Self.fileStamp.string(from: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        let startText = sessionStart.map { dateFormatter.string(from: $0) } ?? "--"

        var lines: [String] = [
            "==================================================",
            t("InfiniCal 电池校准分析报告"),
            "==================================================",
            tf("设备型号: {p}", hardwareModel),
            tf("电池序列号: {p}", batterySerial),
            tf("校准开始时间: {p}", startText),
            tf("校准结束时间: {p}", dateFormatter.string(from: Date())),
            tf("起始放电电量: {p}%", "\(dischargeStartPercentage)"),
            tf("总放电时长: {p}", finalDischargeDurationText),
            tf("循环次数: {p}", "\(cycleCount)"),
            tf("设计容量: {p} mAh", String(format: "%.0f", designCapacityMAh)),
            tf("实测容量: {p} Wh ({p} mAh)", String(format: "%.2f", record.calculatedCapacityWh), String(format: "%.0f", record.calculatedCapacityMAh)),
            tf("单次健康度: {p}", String(format: "%.1f%%", record.batteryHealthPercentage)),
            "",
            t("----------------- 多周期加权评估 -----------------")
        ]
        if let aggregated {
            lines += [
                "",
                tf("有效样本数: {p}", "\(aggregated.sessionCount)"),
                tf("综合真实容量: {p} mAh ({p} Wh)", String(format: "%.0f", aggregated.capacityMAh), String(format: "%.2f", aggregated.capacityWh)),
                tf("综合真实健康度: {p}", String(format: "%.1f%%", aggregated.healthPercent)),
                tf("置信度: {p}", String(format: "%.0f%%", aggregated.confidence))
            ]
        }
        lines += [
            "",
            t("----------------- 电芯性能与内阻 -----------------"),
            tf("直流内阻 (DCIR): {p}", internalResistanceMilliohm > 0 ? String(format: "%.1f mΩ", internalResistanceMilliohm) : "--"),
            tf("电芯电压: {p}", cellVoltages.map { String(format: "%.3fV", $0) }.joined(separator: ", ")),
            tf("电芯压差 (ΔV): {p}", String(format: "%.1f mV", cellDeltaMillivolts)),
            tf("放电能量: {p} Wh ({p} Ah)", String(format: "%.2f", dischargeEnergyWh), String(format: "%.3f", dischargeEnergyAh)),
            tf("复充能量: {p} Wh ({p} Ah)", String(format: "%.2f", rechargeEnergyWh), String(format: "%.3f", rechargeEnergyAh)),
            tf("库仑效率: {p}", rechargeEnergyAh > 0 ? String(format: "%.1f%%", coulombicEfficiency) : "--"),
            tf("终止电压: {p}", String(format: "%.2f V", voltage)),
            tf("终止温度: {p}", String(format: "%.1f °C", temperature)),
            t("----------------- 过程日志 -----------------")
        ]
        var text = lines.joined(separator: "\n")
        for line in log { text += "\n\(line)" }
        text += "\n==================================================\n"

        sessionReportURL = write(text, name: "InfiniCal_Calibration_Report_\(stamp).txt")
        lastReportURL = sessionReportURL

        var csv = "Timestamp,Percentage,Power(W),Voltage(V),Amperage(A),Temperature(C)\n"
        let iso = ISO8601DateFormatter()
        for point in sessionPoints {
            csv += "\(iso.string(from: point.timestamp)),\(point.percentage),"
            csv += "\(String(format: "%.3f", point.power)),\(String(format: "%.3f", point.voltage)),"
            csv += "\(String(format: "%.3f", point.amperage)),\(String(format: "%.2f", point.temperature))\n"
        }
        sessionCSVURL = write(csv, name: "InfiniCal_Telemetry_\(stamp).csv")
        lastCSVURL = sessionCSVURL

        if let report = sessionReportURL {
            append(tf("报告已导出: {p} → {p}", report.lastPathComponent, report.deletingLastPathComponent().path))
        } else {
            append(t("报告导出失败：目标目录不可写"))
        }
    }

    /// Application Support first (no TCC prompt), then the temporary folder.
    private func write(_ content: String, name: String) -> URL? {
        let manager = FileManager.default
        let directories = [CalibrationStore.directory.appendingPathComponent("Reports", isDirectory: true),
                           manager.temporaryDirectory]
        for directory in directories {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            if (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil { return url }
        }
        return nil
    }

    // MARK: - History

    func deleteRecord(_ record: CalibrationRecord) {
        records = CalibrationStore.delete(id: record.id)
        aggregated = CalibrationStore.aggregate(records)
    }

    func clearHistory() {
        CalibrationStore.clear()
        records = []
        aggregated = nil
    }

    private func refreshLastRunDate() {
        let stamp = defaults.double(forKey: Keys.lastRun)
        lastCalibrationDate = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: - Log

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private func append(_ text: String) {
        log.append("[\(Self.logFormatter.string(from: Date()))] \(text)")
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }
}
