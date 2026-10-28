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

    /// Fraction of wall-clock time the GPU should be executing. The GPU is
    /// driven separately from the CPU workers so it can be dropped on its own
    /// when the die gets hot.
    var gpuDutyCycle: Double {
        switch self {
        case .silent: return 0
        case .balanced: return 0.5
        case .aggressive: return 1
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

    /// SoC draw (CPU + GPU + ANE). Measured through powermetrics when the
    /// privileged helper is installed, otherwise a labelled estimate — never a
    /// number invented from the battery reading.
    @Published var socPowerWatts: Double = 0
    @Published var socPowerQuality: PowerQuality = .unavailable
    /// Display backlight draw. No platform exposes this as a sensor, so it is
    /// always a model output and always labelled as one.
    @Published var displayPowerWatts: Double = 0
    @Published var displayPowerQuality: PowerQuality = .unavailable
    @Published var cpuTemperature: Double = 0
    @Published var internalResistanceMilliohm: Double = 0
    @Published var isGPUStressActive: Bool = false

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

    // MARK: Preconditions

    /// True when the pack is on AC, below full, and the system refuses to
    /// charge it. Calibration cannot pass 预充 in that state.
    @Published var isChargeHeld = false
    /// Set once the user confirms they turned the system charging limit off.
    /// Deliberately in-memory: a fresh launch re-checks, which is what
    /// 「首次运行或启动校准前检查」 asks for.
    @Published var obcAcknowledged = false

    /// Whether the panel may unlock 开始校准.
    var canStart: Bool { !isChargeHeld || obcAcknowledged }

    // MARK: Estimates

    @Published var aiRemainingMinutes: Int = 0
    @Published var aiTrueCapacityMAh: Double = 0
    @Published var aiTrueHealthPercent: Double = 0
    @Published var aiConfidence: Double = 0
    @Published var aggregated: AggregatedHealth?

    // MARK: Insight

    /// Decay trend from the daily history. Nil until there is enough data to
    /// say anything — see `BatteryTrend.minimumSamples`.
    @Published private(set) var trend: BatteryTrend?
    /// Live CPU / GPU / ANE split of `socPowerWatts`; zero when unknown.
    @Published var socCPUWatts: Double = 0
    @Published var socGPUWatts: Double = 0
    @Published var socANEWatts: Double = 0

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
    private var displayAssertionID: IOPMAssertionID = 0
    private var assertionActive = false

    private let gpu = GPUStress()
    private let estimator = PowerEstimator()
    private var gpuUnavailableLogged = false
    /// powermetrics is a root process that takes ~1.5 s to answer, so it is
    /// polled on a slow cadence from a background queue and held in between.
    /// At 30 s the extra energy it burns is well under 1 % of a discharge.
    private var socPowerFetchInFlight = false
    private var lastSocPowerFetch = Date.distantPast
    private var lastSocPowerSuccess: Date?
    private let socPowerInterval: TimeInterval = 30
    private let socPowerStaleAfter: TimeInterval = 90

    /// Accumulated over a discharge so the report can say where the energy went
    /// instead of only how much of it there was.
    private var splitSamples = 0
    private var splitCPUSum = 0.0
    private var splitGPUSum = 0.0
    private var splitANESum = 0.0
    private var processTally: [String: Int] = [:]
    private var processSamples = 0
    /// The mode the discharge actually ran under. `stressMode` can be changed
    /// mid-session, and the report must not describe a run by the setting that
    /// happened to be selected when it finished.
    private var sessionStressMode: DischargeStressMode = .balanced

    /// Consecutive ticks the pack has been held below full while on AC. macOS
    /// gives no readable flag for 「优化电池充电」 or 「充电上限」 — verified by
    /// diffing `AppleSmartBattery` before and after toggling it: the property
    /// list is identical apart from live counters. The hold itself is the only
    /// observable symptom, so it is what the gate watches.
    private var chargeHoldTicks = 0

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
        trend = BatteryTrend.compute(days: DailyHistory.shared.days)
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
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID) }
    }

    func beginTelemetryPage() {
        telemetryPageUsers += 1
        // The daily history moves at most once a day; recomputing on entry
        // keeps the trend from going stale in a long-running process.
        trend = BatteryTrend.compute(days: DailyHistory.shared.days)
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

    /// Returns false when a precondition refused the run, so the caller can put
    /// its own mirror state back instead of showing a session that never began.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }

        // A fresh read, because the gate may be evaluated from the menu bar
        // before the calibration page has ever ticked.
        if !obcAcknowledged, Self.isHoldingCharge(BatteryReader.read()) {
            chargeHoldTicks = 5
            isChargeHeld = true
            append(t("已取消启动：系统正在限制充电，无法充至 100%。请先关闭「优化电池充电」或调高「充电上限」"))
            return false
        }

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
        splitSamples = 0
        splitCPUSum = 0
        splitGPUSum = 0
        splitANESum = 0
        processTally.removeAll()
        processSamples = 0
        sessionStressMode = stressMode

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
        return true
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
        stopTelemetryIfIdle()
    }

    /// The 1 Hz timer is only needed while a session runs or the panel is on
    /// screen. `finish()` used to leave it running for the life of the process.
    private func stopTelemetryIfIdle() {
        guard !isRunning, telemetryPageUsers == 0 else { return }
        timer?.invalidate()
        timer = nil
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
        updateChargeHold(snapshot)

        let smoothedPower = model.smoothPower(batteryPower)
        refreshThermal()
        refreshPowerSources(now: now)

        if let resistance = dcir.feed(uptime: uptime, currentAmps: signedAmperage, voltageVolts: voltage) {
            internalResistanceMilliohm = resistance
        }

        let point = CalibrationSample(timestamp: now,
                                      percentage: Double(percentage),
                                      power: batteryPower,
                                      voltage: voltage,
                                      amperage: signedAmperage,
                                      temperature: temperature,
                                      socPower: socPowerWatts,
                                      socPowerQuality: socPowerQuality,
                                      displayPower: displayPowerWatts,
                                      displayPowerQuality: displayPowerQuality)
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

    // MARK: - Charging precondition

    /// The only symptom macOS exposes for a charge hold. It cannot say *why*
    /// the pack is not charging, so the UI names the likely causes instead of
    /// claiming one.
    ///
    /// Above 98 % the pack is topping off and pulses charging on and off; that
    /// is normal and must not read as a limit. A BCLM ceiling is InfiniCal's own
    /// charge-limit feature and `start()` lifts it, so it is excluded too.
    static func isHoldingCharge(_ snapshot: BatterySnapshot) -> Bool {
        guard snapshot.isPluggedIn,
              !snapshot.isCharging,
              !snapshot.fullyCharged,
              snapshot.percentage > 0,
              snapshot.percentage < 98 else { return false }
        return !ChargeController.hasChargeCeiling()
    }

    /// Five consecutive ticks, so the pause between two top-off pulses at 99 %
    /// does not raise a false alarm. Suspended while a session runs: a session
    /// holds the pack down on purpose, and that is not a precondition failure.
    private func updateChargeHold(_ snapshot: BatterySnapshot, force: Bool = false) {
        guard !isRunning else {
            chargeHoldTicks = 0
            isChargeHeld = false
            return
        }
        let held = Self.isHoldingCharge(snapshot)
        chargeHoldTicks = held ? chargeHoldTicks + 1 : 0
        if held, force { chargeHoldTicks = max(chargeHoldTicks, 5) }
        isChargeHeld = held && chargeHoldTicks >= 5
    }

    /// Re-reads the pack on demand — the 「刷新状态」 button.
    func refreshChargeHold() {
        let snapshot = BatteryReader.read()
        apply(snapshot)
        updateChargeHold(snapshot, force: true)
    }

    /// The user says the system limit is off. Trust it for this launch.
    func acknowledgeChargeHold() {
        obcAcknowledged = true
        append(t("已确认关闭系统充电限制，允许开始校准"))
    }

    private func updateEstimates(smoothedPower: Double) {
        let fallbackCap = rawMaxCapacityMAh > 500 ? rawMaxCapacityMAh : max(designCapacityMAh * 0.93, 1)
        let estimate = model.inferTrueHealth(records: records,
                                             designCapacityMAh: designCapacityMAh,
                                             hardwareMaxCapacityMAh: fallbackCap)
        aiTrueCapacityMAh = estimate.capacityMAh
        aiTrueHealthPercent = estimate.healthPercent
        aiConfidence = estimate.confidence

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
        // The span this phase will extrapolate from starts here, so anything
        // the pack happened to give up while topping up must not be counted.
        integrator.resetDischargeBucket()
        dischargeStartPercentage = percentage
        dischargeStart = Date()
        dischargeCurve.removeAll()
        dischargeCurve.append(CalibrationSample(timestamp: Date(),
                                                percentage: Double(percentage),
                                                power: batteryPower,
                                                voltage: voltage,
                                                amperage: signedAmperage,
                                                temperature: temperature,
                                                socPower: socPowerWatts,
                                                socPowerQuality: socPowerQuality,
                                                displayPower: displayPowerWatts,
                                                displayPowerQuality: displayPowerQuality))
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
        // Everything charged before this moment belongs to the pre-charge. Only
        // what follows is the recharge the discharge is compared against.
        integrator.resetRechargeBucket()
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
        trend = BatteryTrend.compute(days: DailyHistory.shared.days)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastRun)
        refreshLastRunDate()
        if splitSamples > 0 {
            append(tf("功耗归因: CPU {p} W · GPU {p} W · ANE {p} W",
                      String(format: "%.2f", splitCPUSum / Double(splitSamples)),
                      String(format: "%.2f", splitGPUSum / Double(splitSamples)),
                      String(format: "%.2f", splitANESum / Double(splitSamples))))
        }
        notify(t("校准完成"), tf("真实容量 {p} mAh，健康度 {p}。", String(format: "%.0f", measuredCapacityMAh), String(format: "%.1f%%", measuredHealth)))
        stopTelemetryIfIdle()
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
        startGPULoad()
    }

    private func stopStressLoad() {
        stopGPULoad()
        guard !stressTasks.isEmpty else { return }
        for task in stressTasks { task.cancel() }
        stressTasks.removeAll()
        append(t("已停止放电负载"))
    }

    /// GPU load runs on its own axis so the thermal guard can drop it while the
    /// CPU workers keep going.
    private func startGPULoad() {
        guard stressMode.gpuDutyCycle > 0 else { return }
        guard gpu.isAvailable else {
            if !gpuUnavailableLogged {
                gpuUnavailableLogged = true
                append(t("未找到可用的 GPU 计算设备，GPU 加压跳过"))
            }
            return
        }
        gpu.start(dutyCycle: stressMode.gpuDutyCycle)
        isGPUStressActive = true
        append(t("GPU 加压已启动"))
    }

    private func stopGPULoad() {
        guard isGPUStressActive else { return }
        gpu.stop()
        isGPUStressActive = false
        append(t("GPU 加压已停止"))
    }

    // MARK: - Thermal protection

    /// Die temperature we refuse to exceed while injecting load ourselves.
    /// Apple Silicon throttles around 100–105 °C; cutting at 95 °C keeps the
    /// stress load from being the thing that heats the machine up. This is a
    /// self-imposed policy, not a value read from the hardware.
    private let socTemperatureCeiling: Double = 95
    private let socTemperatureResume: Double = 85
    /// The GPU line sits below the SoC line: the GPU is the hottest thing we add
    /// and the cheapest to take back, so it comes off first and the CPU load
    /// keeps running.
    private let gpuTemperatureCeiling: Double = 90
    private let gpuTemperatureResume: Double = 82

    private func handleThermalCutoff() {
        guard phase == .discharging else { return }
        let resumeLine = min(resumeTemperature, highTemperature - 1)
        // Two independent sensors, because a 45 °C cell and a 95 °C die are
        // both unsafe and neither implies the other.
        let cellHot = temperature >= highTemperature
        let socHot = cpuTemperature >= socTemperatureCeiling

        if (cellHot || socHot), !isThermalCutoffActive {
            isThermalCutoffActive = true
            stopStressLoad()
            let source = cellHot ? t("电芯") : t("SoC")
            let value = cellHot ? temperature : cpuTemperature
            let limit = cellHot ? highTemperature : socTemperatureCeiling
            append(tf("过热保护（{p}）: {p}°C ≥ 阈值 {p}°C，已暂停负载", source, String(format: "%.1f", value), "\(Int(limit))"))
            notify(t("过热保护已触发"), tf("温度已达 {p}°C（{p}），放电负载已暂停等待降温。", String(format: "%.1f", value), source))
        } else if isThermalCutoffActive, temperature <= resumeLine, cpuTemperature <= socTemperatureResume {
            isThermalCutoffActive = false
            startStressLoad()
            append(tf("温度恢复: {p}°C ≤ 恢复线 {p}°C，已恢复负载", String(format: "%.1f", temperature), "\(Int(resumeLine))"))
        }

        // GPU sub-fuse, only meaningful while the main load is allowed to run.
        guard !isThermalCutoffActive else { return }
        if isGPUStressActive, cpuTemperature >= gpuTemperatureCeiling {
            stopGPULoad()
            append(tf("GPU 过热保护: {p}°C ≥ 阈值 {p}°C，已单独撤除 GPU 负载", String(format: "%.1f", cpuTemperature), "\(Int(gpuTemperatureCeiling))"))
        } else if !isGPUStressActive, stressMode.gpuDutyCycle > 0, gpu.isAvailable,
                  cpuTemperature > 0, cpuTemperature <= gpuTemperatureResume {
            startGPULoad()
        }
    }

    // MARK: - Host telemetry

    private func refreshThermal() {
        if let cpu = hidCPUTemperature() ?? smcCPUTemperature() {
            cpuTemperature = cpu
        }
    }

    /// SoC and display draw for the current sample. Both carry their quality:
    /// powermetrics is a measurement, the brightness model is not, and neither
    /// is ever promoted to look like a sensor.
    private func refreshPowerSources(now: Date) {
        let display = estimator.estimateDisplay()
        displayPowerWatts = display.watts ?? 0
        displayPowerQuality = display.watts == nil ? .unavailable : display.quality

        guard HelperClient.shared.lastKnownInstalled else {
            let estimate = estimator.estimateSoC()
            socPowerWatts = estimate.watts ?? 0
            socPowerQuality = estimate.watts == nil ? .unavailable : estimate.quality
            return
        }

        if let last = lastSocPowerSuccess, now.timeIntervalSince(last) <= socPowerStaleAfter {
            socPowerQuality = .measured
        } else {
            socPowerQuality = .unavailable
            socPowerWatts = 0
        }
        fetchSocPowerIfDue(now: now)
    }

    /// powermetrics answers in ~1.5 s, so the call runs off the main thread and
    /// the result is held until the next poll.
    private func fetchSocPowerIfDue(now: Date) {
        guard !socPowerFetchInFlight,
              now.timeIntervalSince(lastSocPowerFetch) >= socPowerInterval else { return }
        socPowerFetchInFlight = true
        lastSocPowerFetch = now
        // Read on the main thread: the sampler blocks for a second and there is
        // no reason to pay that outside a session.
        let attributing = isRunning
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let split = HelperClient.shared.socPowerSplit()
            let processes = attributing
                ? ProcessSampler.topProcesses(interval: 1.0, limit: 3, excluding: [getpid()])
                : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.socPowerFetchInFlight = false
                guard let split else { return }
                self.socPowerWatts = split.combined
                self.socPowerQuality = .measured
                self.socCPUWatts = split.cpu
                self.socGPUWatts = split.gpu
                self.socANEWatts = split.ane
                self.lastSocPowerSuccess = Date()
                if self.isRunning { self.recordSplit(split, processes: processes) }
            }
        }
    }

    private func recordSplit(_ split: (cpu: Double, gpu: Double, ane: Double, combined: Double),
                             processes: [ProcessLoad]) {
        splitSamples += 1
        splitCPUSum += split.cpu
        splitGPUSum += split.gpu
        splitANESum += split.ane
        guard !processes.isEmpty else { return }
        processSamples += 1
        for process in processes { processTally[process.name, default: 0] += 1 }
    }

    /// Apple Silicon die temperature from the HID sensor page.
    ///
    /// Only `PMU tdie*` is accepted. Intel exposes a different set whose names
    /// also contain "die" — CPU Proximity, GPU Die, PCH Die — and averaging
    /// them into a value labelled "CPU 温度" read 96 °C on a MacBookPro15,1
    /// while `powermetrics` reported 43 °C for the same machine. Intel goes
    /// through `smcCPUTemperature()` instead.
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
            guard name.lowercased().contains("tdie") else { continue }
            guard let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, 0x000F0000)
            if celsius > 15, celsius < 110 { readings.append(celsius) }
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    /// Intel CPU temperature straight from the SMC. `TC0D` is the die sensor —
    /// the same quantity `powermetrics` prints as "CPU die temperature" — with
    /// the proximity sensors as fallbacks on models that omit it.
    private func smcCPUTemperature() -> Double? {
        for key in ["TC0D", "TC0P", "TC0E", "TC0F"] {
            if let value = try? SMC.shared.readDouble(key), value > 10, value < 115 {
                return value
            }
        }
        return nil
    }

    // MARK: - Sleep block

    private func enableSleepBlock() {
        guard !assertionActive else { return }
        guard createAssertion(&assertionID,
                              kIOPMAssertionTypePreventUserIdleSystemSleep,
                              "InfiniCal Calibration") else { return }
        assertionActive = true
        // Display sleep is a second, independent assertion: the panel has to
        // stay readable and the sample interval must not be disturbed by the
        // screen powering down. A headless or clamshell Mac may refuse it.
        if createAssertion(&displayAssertionID,
                           kIOPMAssertionTypePreventUserIdleDisplaySleep,
                           "InfiniCal Calibration Display") {
            append(t("已阻止系统睡眠与息屏，保证采样连续"))
        } else {
            append(t("已阻止系统睡眠（息屏断言未生效）"))
        }
    }

    private func disableSleepBlock() {
        guard assertionActive || displayAssertionID != 0 else { return }
        if assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            assertionActive = false
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        append(t("已恢复系统睡眠与息屏策略"))
    }

    private func createAssertion(_ id: inout IOPMAssertionID,
                                 _ type: String,
                                 _ name: String) -> Bool {
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString,
                                                 &created)
        guard result == kIOReturnSuccess else { return false }
        id = created
        return true
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
                temperature: slice.reduce(0) { $0 + $1.temperature } / count,
                socPower: slice.reduce(0) { $0 + $1.socPower } / count,
                socPowerQuality: slice.last?.socPowerQuality ?? .unavailable,
                displayPower: slice.reduce(0) { $0 + $1.displayPower } / count,
                displayPowerQuality: slice.last?.displayPowerQuality ?? .unavailable
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
            tf("终止温度: {p}", String(format: "%.1f °C", temperature))
        ]

        if splitSamples > 0 {
            let cpu = splitCPUSum / Double(splitSamples)
            let gpu = splitGPUSum / Double(splitSamples)
            let ane = splitANESum / Double(splitSamples)
            let total = max(0.001, cpu + gpu + ane)
            lines += [
                "",
                t("----------------- 功耗归因 -----------------"),
                tf("SoC 分项均值: CPU {p} W ({p}%) · GPU {p} W ({p}%) · ANE {p} W ({p}%)",
                   String(format: "%.2f", cpu), "\(Int(cpu / total * 100))",
                   String(format: "%.2f", gpu), "\(Int(gpu / total * 100))",
                   String(format: "%.2f", ane), "\(Int(ane / total * 100))"),
                tf("分项采样: {p} 次（每 30 秒一次）", "\(splitSamples)")
            ]
            let processes = topProcessSummary()
            if !processes.isEmpty {
                lines.append(tf("放电期间高频进程: {p}", processes))
            }
            if sessionStressMode == .silent, gpu / total >= 0.4 {
                lines.append(t("GPU 占比偏高，但本次未施加 GPU 负载：放电期间可能有图形密集型应用在活跃。"))
            }
            lines.append(t("说明: 分项为 powermetrics 实测；进程占比是 CPU 占用，不是焦耳，仅作粗粒度参考。"))
        }

        lines.append(t("----------------- 过程日志 -----------------"))
        var text = lines.joined(separator: "\n")
        for line in log { text += "\n\(line)" }
        text += "\n==================================================\n"

        sessionReportURL = write(text, name: "InfiniCal_Calibration_Report_\(stamp).txt")
        lastReportURL = sessionReportURL

        var csv = "Timestamp,Percentage,Power(W),Voltage(V),Amperage(A),Temperature(C),"
        csv += "SocPower(W),SocPowerSource,DisplayPower(W),DisplayPowerSource\n"
        let iso = ISO8601DateFormatter()
        for point in sessionPoints {
            csv += "\(iso.string(from: point.timestamp)),\(point.percentage),"
            csv += "\(String(format: "%.3f", point.power)),\(String(format: "%.3f", point.voltage)),"
            csv += "\(String(format: "%.3f", point.amperage)),\(String(format: "%.2f", point.temperature)),"
            csv += "\(String(format: "%.2f", point.socPower)),\(Self.qualityToken(point.socPowerQuality)),"
            csv += "\(String(format: "%.2f", point.displayPower)),\(Self.qualityToken(point.displayPowerQuality))\n"
        }
        sessionCSVURL = write(csv, name: "InfiniCal_Telemetry_\(stamp).csv")
        lastCSVURL = sessionCSVURL

        if let report = sessionReportURL {
            append(tf("报告已导出: {p} → {p}", report.lastPathComponent, report.deletingLastPathComponent().path))
        } else {
            append(t("报告导出失败：目标目录不可写"))
        }
    }

    /// Most frequently seen names in the discharge window, with how often they
    /// appeared out of the samples taken.
    private func topProcessSummary() -> String {
        guard processSamples > 0 else { return "" }
        return processTally
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { tf("{p} ({p}/{p})", $0.key, "\($0.value)", "\(processSamples)") }
            .joined(separator: " · ")
    }

    /// Stable ASCII tokens: a CSV is data, not UI, so it must not be localised.
    private static func qualityToken(_ quality: PowerQuality) -> String {
        switch quality {
        case .measured: return "measured"
        case .estimated: return "estimated"
        case .unavailable: return "unavailable"
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
