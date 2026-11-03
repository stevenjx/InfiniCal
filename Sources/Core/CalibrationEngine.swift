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

/// How deep a calibration cycle goes.
///
/// This is deliberately a separate axis from `DischargeStressMode`: that one
/// decides how hard the pack is drained, this one decides how far. A quick
/// check can still be run with a loud load, and a deep run can be silent.
///
/// The depth is what makes the result trustworthy: capacity is extrapolated
/// from the charge moved between two known percentages, so a shallow cycle
/// measures a smaller slice and cannot stand in for a full-capacity run.
enum CalibrationPreset: String, CaseIterable, Identifiable {
    case quickCheck
    case standard
    case deep

    var id: String { rawValue }

    /// Where the discharge phase stops. This is the value the engine already
    /// uses for `dischargeTarget`.
    var dischargeTarget: Int {
        switch self {
        case .quickCheck: return 50
        case .standard: return 20
        case .deep: return 10
        }
    }

    var title: String {
        switch self {
        case .quickCheck: return t("快速检查")
        case .standard: return t("标准校准")
        case .deep: return t("深度校准")
        }
    }

    var detail: String {
        switch self {
        case .quickCheck: return t("放电到约 50%，只做初步排查")
        case .standard: return t("放电到约 20% 后复充，适合日常维护")
        case .deep: return t("放电到约 10% 后复充，测量最完整")
        }
    }

    /// Rough wall-clock estimate. The real duration depends on pack size and
    /// the stress mode, so this is stated as a range rather than a promise.
    var estimatedHours: String {
        switch self {
        case .quickCheck: return t("约 1–2 小时")
        case .standard: return t("约 3–5 小时")
        case .deep: return t("约 5–8 小时")
        }
    }

    var risk: String {
        switch self {
        case .quickCheck: return t("风险最低，但结果只作参考")
        case .standard: return t("需要完整一次充放电循环")
        case .deep: return t("接近放空，损耗与发热最大，非必要不建议频繁执行")
        }
    }

    /// A shallow cycle cannot describe the whole pack, so its result is never
    /// allowed to reach the medium/high grades that feed the health average.
    var capsQualityAtLow: Bool { self == .quickCheck }

    /// A deep cycle is the only one that takes the pack close to empty, so it
    /// must never start without the user saying so — schedules and catch-up
    /// runs downgrade it. Resuming an interrupted session keeps its own depth,
    /// because the user already chose it.
    var requiresExplicitUserAction: Bool { self == .deep }
}

// MARK: - Engine

final class CalibrationEngine: ObservableObject {

    static let shared = CalibrationEngine()

    // MARK: Live telemetry (1 Hz)

    @Published var phase: CalibrationPhase = .idle {
        didSet {
            if isRunning {
                qualityPhases.insert(phase.rawValue)
                phaseTimeline.append(CalibrationPhaseEvent(phase: phase.rawValue, date: Date()))
                saveCheckpoint(reason: "phaseChanged")
            }
        }
    }
    @Published private(set) var resultQuality: CalibrationQuality?
    private var phaseTimeline: [CalibrationPhaseEvent] = []
    private var exportDroppedSamples = 0
    private var lastCompletedRecord: CalibrationRecord?
    private var qualityPhases: Set<String> = []
    private var qualityIssues: Set<String> = []
    private var negativeSamples = 0
    private var positiveSamples = 0
    @Published private(set) var pendingRecovery: CalibrationCheckpoint?
    @Published private(set) var recoveryError: String?
    private(set) var recoveredChargeLimit: Int?
    func takeRecoveredChargeLimit() -> Int? {
        defer { recoveredChargeLimit = nil }
        return recoveredChargeLimit
    }
    private let checkpointKey = "calibrationRecoveryCheckpoint.v1"
    private var sessionID = UUID()
    private var sessionRestoreLimit = 80
    private var lastCheckpointAt = Date.distantPast
    private var lastSessionUptime: TimeInterval?
    var needsRecovery: Bool { pendingRecovery != nil || recoveryError != nil }
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
    /// Set when a discharge phase is sitting on adapter power because the
    /// machine cannot be forced to drain while plugged in.
    @Published var needsUnplugForDischarge: Bool = false

    // MARK: Preconditions

    /// True when the pack is on AC, below full, and the system refuses to
    /// charge it. Advisory only: `start()` lifts this app's own ceiling and then
    /// reports whether charging actually began, so the run is not blocked here.
    @Published var isChargeHeld = false

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
    /// Calibration depth. Kept separate from `stressMode`: the user picks how
    /// deep to cycle, and independently how hard to load the pack.
    @Published var preset: CalibrationPreset = .standard {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset) }
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
        static let preset = "calibrationPreset"
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
    /// The preset this session actually started with. The report must describe
    /// the run by the depth it ran at, not by a setting changed afterwards.
    private var sessionPreset: CalibrationPreset = .standard

    /// Consecutive ticks the pack has been held below full while on AC. macOS
    /// gives no readable flag for 「优化电池充电」 or 「充电上限」 — verified by
    /// diffing `AppleSmartBattery` before and after toggling it: the property
    /// list is identical apart from live counters. The hold itself is the only
    /// observable symptom, so it is what the gate watches.
    private var chargeHoldTicks = 0
    private var fullyCharged = false
    private var fullChargeTicks = 0
    private var noChargeTicks = 0
    @Published private(set) var chargingIssue: String?
    private(set) var startFailureReason: String?
    /// Consecutive ticks spent plugged in without any pack current during the
    /// discharge phase.
    private var noDischargeTicks = 0
    /// Ticks spent inside a drain phase; drives the 2 s re-assert of the
    /// adapter switch.
    private var drainTicks = 0
    private var adapterFailureLogged = false
    /// One diagnostic line per session is enough when the sampler's field names
    /// do not match.
    private var socPowerParseFailureLogged = false

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
        if let raw = defaults.string(forKey: Keys.preset),
           let stored = CalibrationPreset(rawValue: raw) {
            preset = stored
        }
        let target = defaults.integer(forKey: Keys.dischargeTarget)
        // On a fresh install follow the stored preset instead of a hard-coded
        // default, so the dialog and the control bar never disagree.
        dischargeTarget = target > 0 ? target : preset.dischargeTarget
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

        if let data = defaults.data(forKey: checkpointKey) {
            if let checkpoint = try? JSONDecoder().decode(CalibrationCheckpoint.self, from: data),
               checkpoint.schemaVersion == 1,
               CalibrationPhase(rawValue: checkpoint.phase) != nil,
               (1...100).contains(checkpoint.restoreLimit),
               (1...99).contains(checkpoint.targetPercentage) {
                pendingRecovery = checkpoint
            } else {
                recoveryError = t("校准恢复记录无法读取；请执行安全清理")
            }
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

    // MARK: - Recovery journal

    private func saveCheckpoint(reason: String) {
        let now = Date()
        let checkpoint = CalibrationCheckpoint(
            sessionID: sessionID, phase: phase.rawValue,
            startedAt: sessionStart ?? now, lastSampleAt: now,
            targetPercentage: dischargeTarget, restoreLimit: sessionRestoreLimit,
            stressMode: sessionStressMode.rawValue,
            adapterControl: ChargeController.shared.activeAdapterKey,
            chargeControl: ChargeController.shared.capabilities.strategy.rawValue,
            reason: reason,
            preset: sessionPreset.rawValue)
        do {
            defaults.set(try JSONEncoder().encode(checkpoint), forKey: checkpointKey)
            lastCheckpointAt = now
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    /// Safe to retry. Never creates a sleep assertion, load or adapter-off request.
    @discardableResult
    func cleanInterruptedSession(discard: Bool = false) -> Bool {
        guard !isRunning else { return false }
        stopStressLoad()
        stopDrainPulse()
        disableSleepBlock()
        let controller = ChargeController.shared
        _ = HelperClient.shared.refreshInstallState()
        _ = controller.detectCapabilities()
        controller.restoreAdapterLeftOff()
        controller.endForcedDischarge()
        guard controller.adapterRestoreError == nil else {
            recoveryError = controller.adapterRestoreError
            return false
        }
        do {
            // Clears charge-inhibit keys as well as persisted ceilings.
            try controller.prepareForFullCharge()
            let requested = pendingRecovery?.restoreLimit ?? storageLevel
            let limit = controller.hasPersistentCeiling ? max(80, requested) : requested
            if controller.capabilities.strategy != .unavailable {
                try controller.applyChargeLimit(limit)
            } else if pendingRecovery?.chargeControl != ChargeStrategy.unavailable.rawValue {
                throw HelperError.smc(t("恢复充电控制不可用，请更新助手后重试"))
            }
            FanController.shared.restoreSystemControl()
            if let error = FanController.shared.lastError {
                throw HelperError.smc(error)
            }
            recoveredChargeLimit = limit
            recoveryError = nil
            append(t("已完成校准安全清理，未启动放电或加压"))
            if discard {
                recoveredChargeLimit = limit
                defaults.set(limit, forKey: "chargeVal")
                defaults.removeObject(forKey: checkpointKey)
                pendingRecovery = nil
            }
            return true
        } catch {
            recoveryError = error.localizedDescription
            return false
        }
    }

    /// An unobserved gap cannot produce a continuous capacity measurement.
    /// Continue the workflow with a fresh full cycle, never reuse old buckets.
    @discardableResult
    func restartInterruptedSession() -> Bool {
        guard let checkpoint = pendingRecovery,
              cleanInterruptedSession(), BatteryReader.read().isPluggedIn else { return false }
        let backup = defaults.data(forKey: checkpointKey)
        defaults.removeObject(forKey: checkpointKey)
        pendingRecovery = nil
        dischargeTarget = checkpoint.targetPercentage
        stressMode = DischargeStressMode(rawValue: checkpoint.stressMode) ?? .silent
        // Journals written before presets existed fall back to standard; the
        // stored depth is already carried by targetPercentage either way.
        preset = checkpoint.preset.flatMap(CalibrationPreset.init(rawValue:)) ?? .standard
        if start() {
            sessionRestoreLimit = checkpoint.restoreLimit
            saveCheckpoint(reason: "restartedAfterInterruption")
            append(t("上次测量已中断，已从预充重新测量；中断区间不计入容量"))
            return true
        }
        defaults.set(backup, forKey: checkpointKey)
        pendingRecovery = checkpoint
        recoveryError = startFailureReason
        return false
    }

    // MARK: - Session control

    /// Returns false when a precondition refused the run, so the caller can put
    /// its own mirror state back instead of showing a session that never began.
    @discardableResult
    func start() -> Bool {
        guard !updateSuspended else { return false }
        guard !isRunning else { return false }
        guard !needsRecovery else {
            startFailureReason = t("请先处理上次校准的恢复记录")
            return false
        }
        startFailureReason = nil

        let snapshot = BatteryReader.read()
        apply(snapshot)
        guard snapshot.isPresent else {
            let message = t("校准未开始：未检测到电池")
            startFailureReason = message
            append(message)
            return false
        }
        // Every phase needs the adapter: pre-charge, recharge, and a discharge
        // that has to switch away from it. Starting on battery produced a run
        // that never charged and then stalled at the first phase change.
        guard snapshot.isPluggedIn else {
            let message = t("校准未开始：请先连接电源适配器。整个流程需要先充满、接电放电、再充满。")
            startFailureReason = message
            append(message)
            return false
        }
        sessionID = UUID()
        sessionStart = Date()
        sessionRestoreLimit = max(1, min(100, defaults.object(forKey: "chargeVal") as? Int ?? storageLevel))
        sessionStressMode = stressMode
        sessionPreset = preset
        saveCheckpoint(reason: "preparing")
        guard recoveryError == nil else { return false }
        // Fresh key table: the log below is what identifies this machine's
        // control mechanism, so it must not come from a stale launch-time scan.
        _ = ChargeController.shared.detectCapabilities()
        // A running auto-discharge hold would keep writing the user's ceiling
        // every 400 ms and the pre-charge would never reach full.
        stopDrainPulse()
        do {
            try ChargeController.shared.prepareForFullCharge()
        } catch {
            let message = tf("校准未开始：恢复充电失败 — {p}", error.localizedDescription)
            startFailureReason = message
            append(message)
            pendingRecovery = defaults.data(forKey: checkpointKey).flatMap { try? JSONDecoder().decode(CalibrationCheckpoint.self, from: $0) }
            return false
        }

        resultQuality = nil
        phaseTimeline = []
        exportDroppedSamples = 0
        lastCompletedRecord = nil
        qualityPhases = []
        qualityIssues = ["使用私有硬件控制路径"]
        negativeSamples = 0
        positiveSamples = 0
        isRunning = true
        lastSessionUptime = ProcessInfo.processInfo.systemUptime
        noChargeTicks = 0
        chargingIssue = nil
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
        needsUnplugForDischarge = false
        noDischargeTicks = 0
        drainTicks = 0
        adapterFailureLogged = false
        socPowerParseFailureLogged = false
        sessionPoints.removeAll()
        dischargeCurve.removeAll()
        splitSamples = 0
        splitCPUSum = 0
        splitGPUSum = 0
        splitANESum = 0
        processTally.removeAll()
        processSamples = 0
        sessionStressMode = stressMode
        sessionPreset = preset

        enableSleepBlock()
        // The run heats the SoC on purpose; the fans follow 风扇控制's curve for
        // its duration and are handed back when it ends.
        FanController.shared.beginSessionCooling()
        append(t(">>> 开始电池校准 <<<"))
        let caps = ChargeController.shared.capabilities
        let present = Set(caps.rawKeys.map { $0.0 })
        // Which adapter levers this machine has decides whether the discharge
        // phase can run on AC, so it is logged before anything is written.
        append("SMC 适配器键: " + ["ACEN", "CH0I", "CH0J", "CHIE", "CHWA"]
            .map { "\($0)=\(present.contains($0) ? "有" : "无")" }
            .joined(separator: " "))
        append("SMC: " + caps.rawKeys.map { "\($0.0)=\($0.1)" }.joined(separator: "; "))
        append(tf("特权助手协议版本：{p}", "\(HelperClient.shared.helperProtocolVersion)"))
        append(tf("放电方式：{p}", drainLeverDescription))

        phase = .chargingToFull
        dischargeStart = nil
        append(t("已发送恢复充电指令，等待电池实际充电并达到满充"))
        stopStressLoad()
        return true
    }

    func stop(reason: String? = nil) {
        guard isRunning else { return }
        saveCheckpoint(reason: reason ?? "userStopped")
        resultQuality = assessQuality(completed: false)
        pendingRecovery = defaults.data(forKey: checkpointKey).flatMap { try? JSONDecoder().decode(CalibrationCheckpoint.self, from: $0) }
        stopStressLoad()
        releaseDischarge(limit: sessionRestoreLimit)
        disableSleepBlock()
        FanController.shared.endSessionCooling()
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
    private var updateSuspended = false

    func prepareIdleForUpdate() {
        guard !isRunning else { return }
        updateSuspended = true
        stopStressLoad()
        stopDrainPulse()
        disableSleepBlock()
    }

    func resumeAfterUpdateCancellation() { updateSuspended = false }

    func prepareForTermination() {
        guard isRunning else { return }
        saveCheckpoint(reason: "applicationTermination")
        stopStressLoad()
        releaseDischarge(limit: sessionRestoreLimit)
        disableSleepBlock()
        FanController.shared.endSessionCooling()
        isRunning = false
        phase = .idle
    }

    // MARK: - Tick

    private func tick() {
        guard !updateSuspended else { return }
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
        if let last = lastSessionUptime, uptime - last > 5 {
            qualityIssues.insert("采样中断")
            stop(reason: t("采样中断超过 5 秒，校准已暂停；请处理恢复记录"))
            return
        }
        lastSessionUptime = uptime
        if now.timeIntervalSince(lastCheckpointAt) >= 5 { saveCheckpoint(reason: "sampling") }
        guard recoveryError == nil else {
            stop(reason: t("保存校准恢复记录失败，已停止校准"))
            return
        }

        sessionPoints.append(point)
        if sessionPoints.count > 120_000 {
            sessionPoints.removeFirst(20_000)
            exportDroppedSamples += 20_000
        }

        if phase == .discharging, signedAmperage < -0.05 { negativeSamples += 1 }
        if phase == .rechargingToFull, signedAmperage > 0.05 { positiveSamples += 1 }
        if isThermalCutoffActive { qualityIssues.insert("发生过热保护") }
        if adapterFailureLogged || chargingIssue != nil { qualityIssues.insert("发生控制或充电异常") }
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
        fullyCharged = snapshot.fullyCharged
        if snapshot.percentage >= 100 && snapshot.isPluggedIn {
            fullChargeTicks += 1
        } else {
            fullChargeTicks = 0
        }
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

    private func updateEstimates(smoothedPower: Double) {
        let fallbackCap = rawMaxCapacityMAh > 500 ? rawMaxCapacityMAh : max(designCapacityMAh * 0.93, 1)
        let estimate = model.inferTrueHealth(records: records.filter { $0.quality?.eligibleForAggregation == true },
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
            monitorCharging()
            if isFullChargeConfirmed { beginDischargePhase() }

        case .discharging:
            dischargeEnergyWh = totals.dischargeWh
            dischargeEnergyAh = totals.dischargeAh
            updateDischargeDerived(now: now)
            ensureDischargeOnAC()
            guard isRunning else { return }
            if percentage <= dischargeTarget { endDischargePhase() }

        case .rechargingToFull:
            rechargeEnergyWh = totals.rechargeWh
            rechargeEnergyAh = totals.rechargeAh
            if dischargeEnergyAh > 0, rechargeEnergyAh > 0 {
                coulombicEfficiency = dischargeEnergyAh / rechargeEnergyAh * 100
            }
            monitorCharging()
            if isFullChargeConfirmed { beginHoldPhase() }

        case .holdingAtFull:
            if let start = holdStart, now.timeIntervalSince(start) >= holdDurationSeconds {
                beginStorageDrop()
            }

        case .dischargingToBuffer:
            ensureDischargeOnAC()
            guard isRunning else { return }
            if percentage <= storageLevel { finish() }

        case .idle, .completed:
            break
        }
    }

    private var isFullChargeConfirmed: Bool {
        guard isExternalConnected else { return false }
        if fullyCharged { return true }
        if percentage >= 100 {
            return abs(signedAmperage) <= 0.15 || fullChargeTicks >= 15
        }
        return false
    }

    private func monitorCharging() {
        if isFullChargeConfirmed || (isCharging && signedAmperage > 0.05) {
            noChargeTicks = 0
            chargingIssue = nil
            return
        }
        noChargeTicks += 1
        guard noChargeTicks == 30 else { return }
        let message = isExternalConnected
            ? t("校准等待中：已接电但电池尚未实际充电。充电指令不等于充电成功，请检查系统充电限制、其他电池管理程序与适配器状态。")
            : t("校准等待中：当前未检测到外接供电，请连接电源适配器。")
        chargingIssue = message
        append(message)
    }

    /// Both drain phases require actual negative pack current.
    ///
    /// The lever is re-asserted every 2 s while draining: AlDente pulses its
    /// discharge key because the SMC/macOS resets it, and a single write can
    /// also be refused while the charger is still transitioning.
    private func ensureDischargeOnAC() {
        drainTicks += 1
        if drainTicks % 2 == 0 { reassertDrainLever() }
        guard isRunning else { return }
        if signedAmperage < -0.05 {
            noDischargeTicks = 0
            if needsUnplugForDischarge {
                needsUnplugForDischarge = false
                append(t("已检测到电池供电，开始放电"))
            }
            // The load is started only once the pack is really supplying: on AC
            // it would just heat the machine without moving any charge.
            if phase == .discharging, stressTasks.isEmpty { startStressLoad() }
            return
        }
        stopStressLoad()
        noDischargeTicks += 1
        // Do not release the lever and do not stop the phase: a charge ceiling
        // and an adapter cut both take effect asynchronously, and the old
        // "give up after 60 s and restore the ceiling" path left the phase
        // running with nothing armed, so unplugging the cable — the thing this
        // feature exists to avoid — became the only way forward.
        guard noDischargeTicks == 60, !needsUnplugForDischarge else { return }
        needsUnplugForDischarge = true
        stopStressLoad()
        append(tf("接电状态下 60 秒仍未测到放电电流（已尝试：{p}）。放电指令保持生效，若拔掉电源适配器会立即继续。",
                  drainLeverDescription))
    }

    /// What the current phase actually armed, for the log and the UI hint.
    private var drainLeverDescription: String {
        let controller = ChargeController.shared
        if controller.canSwitchAdapter { return t("适配器断电/DisableInflow（接电时也能放电）") }
        if controller.hasPersistentCeiling { return t("系统充电上限（80% 起）") }
        if controller.canHoldCeiling { return t("BCLM 上限（需要持续重写）") }
        return t("无可用放电杠杆")
    }

    /// Re-writes the adapter key, if this machine has one. The ceiling lever is
    /// pulsed separately (`startDrainPulse`) because it needs a much faster
    /// cadence than the 1 s tick.
    private func reassertDrainLever() {
        let controller = ChargeController.shared
        guard controller.canSwitchAdapter else { return }
        if let reason = controller.beginForcedDischarge() {
            adapterFailureLogged = true
            stop(reason: tf("适配器切换未生效：{p}", reason))
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
        drainTicks = 0
        adapterFailureLogged = false
        holdDischarge()
        guard isRunning else { return }
        startDrain(hold: dischargeTarget)
    }

    /// Starts draining.
    ///
    /// Three levers exist in the world: an adapter key (Apple Silicon CH0I/CH0J/
    /// CHIE), the OS charge limit (macOS 26+), and a raw BCLM ceiling. The
    /// adapter key is preferred because it works for any target and needs no
    /// re-write; MCL is next because powerd keeps it without a pulse but cannot
    /// go below 80 %; BCLM has to be re-written every 400 ms because macOS keeps
    /// putting the value back.
    private func startDrain(hold: Int) {
        if ChargeController.shared.canSwitchAdapter {
            if let failure = ChargeController.shared.beginForcedDischarge() {
                stop(reason: tf("适配器切换请求失败 — {p}", failure))
                return
            }
            // Acceptance is not discharge evidence. The next telemetry tick
            // starts load only after observing negative pack current.
            return
        }
        if ChargeController.shared.hasPersistentCeiling {
            // MCL cannot go below 80 %, so this lever alone reaches the floor and
            // no further. Say so instead of letting the phase look stalled.
            let floor = SystemChargeLimit.minimumSupported
            do {
                try ChargeController.shared.applyChargeLimit(max(floor, hold))
                if hold < floor {
                    append(tf("系统充电上限只能降到 {p}%，本机没有适配器断电键：{p}% 以下需要用电池自行放电",
                              "\(floor)", "\(floor)"))
                } else {
                    append(tf("已通过系统充电上限把目标设为 {p}%，由 powerd 切换到电池供电", "\(hold)"))
                }
            } catch {
                append(tf("系统充电上限写入失败 — {p}", error.localizedDescription))
            }
            return
        }
        // Ceiling lever: the load stays off until the pack actually starts
        // draining, otherwise the machine is heated on AC for up to a minute
        // with nothing to show for it.
        append(tf("已把充电上限设为 {p}%，每 400ms 重写一次，等待系统把供电切到电池（最多 60 秒）", "\(hold)"))
        guard ChargeController.shared.canHoldCeiling else {
            append(t("本机没有可写的 BCLM，也没有适配器断电键，无法用上限方式触发放电"))
            return
        }
        startDrainPulse(limit: hold)
    }

    /// Holds the ceiling at the discharge target. The 400 ms cadence lives in
    /// `ChargeController.holdCeiling` so the normal auto-discharge path can use
    /// exactly the same mechanism.
    private func startDrainPulse(limit: Int) {
        ChargeController.shared.holdCeiling(limit)
    }

    private func stopDrainPulse() {
        ChargeController.shared.stopHoldingCeiling()
    }

    private func endDischargePhase() {
        let hours = Int(dischargeElapsedSeconds) / 3600
        let minutes = (Int(dischargeElapsedSeconds) % 3600) / 60
        finalDischargeDurationText = tf("{p} 小时 {p} 分（平均 {p} W）", "\(hours)", "\(minutes)", String(format: "%.1f", dischargeAveragePower))
        append(tf("放电完成（{p}%），耗时 {p} 小时 {p} 分，平均放电功率 {p} W", "\(dischargeTarget)", "\(hours)", "\(minutes)", String(format: "%.2f", dischargeAveragePower)))

        stopStressLoad()
        // Must stop before the recharge asks for a full ceiling: a running
        // pulse would keep writing the discharge target every 400 ms and the
        // pack would never charge.
        stopDrainPulse()
        do {
            try ChargeController.shared.prepareForFullCharge()
        } catch {
            stop(reason: tf("校准中止：恢复复充失败 — {p}", error.localizedDescription))
            return
        }
        noChargeTicks = 0
        chargingIssue = nil
        fullChargeTicks = 0
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
        // A fresh drain attempt: the counters belong to the phase that is
        // starting, not to the discharge that already finished.
        noDischargeTicks = 0
        drainTicks = 0
        adapterFailureLogged = false
        holdDischarge()
        guard isRunning else { return }
        startDrain(hold: storageLevel)
        notify(t("回落至存储电量"), tf("校准即将完成，正在缓慢放电至 {p}% 存储电量。", "\(storageLevel)"))
    }

    private func assessQuality(completed: Bool) -> CalibrationQuality {
        var issues = qualityIssues
        if ChargeController.shared.usesIntelInflow || ChargeController.shared.activeAdapterKey != nil {
            issues.insert("使用私有硬件控制路径")
        }
        return CalibrationQuality.evaluate(phases: qualityPhases, negativeSamples: negativeSamples,
            positiveSamples: positiveSamples, dischargeAh: dischargeEnergyAh,
            rechargeAh: rechargeEnergyAh, span: dischargeStartPercentage - dischargeTarget,
            issues: issues, backend: ChargeController.shared.capabilities.strategy.rawValue,
            completed: completed, presetCapped: sessionPreset.capsQualityAtLow)
    }

    private func finish() {
        resultQuality = assessQuality(completed: true)
        stopStressLoad()
        releaseDischarge(limit: storageLevel)
        guard chargingIssue == nil else {
            stop(reason: t("校准测量结束，但安全清理失败，请重试清理"))
            return
        }
        disableSleepBlock()
        FanController.shared.endSessionCooling()
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
                                       internalResistanceMilliohm: internalResistanceMilliohm,
                                       quality: resultQuality,
                                       conditions: CalibrationConditions(model: hardwareModel,
                                           backend: ChargeController.shared.capabilities.strategy.rawValue,
                                           stressMode: sessionStressMode.rawValue, target: dischargeTarget,
                                           startPercentage: dischargeStartPercentage,
                                           meanTemperature: dischargeCurve.isEmpty ? 0 : dischargeCurve.reduce(0) { $0 + $1.temperature } / Double(dischargeCurve.count),
                                           meanPower: dischargeAveragePower, designCapacityMAh: designCapacityMAh,
                                           preset: sessionPreset.rawValue))

        lastCompletedRecord = record
        if autoExport {
            exportReports(record: record)
        }
        records = CalibrationStore.append(record)
        if CalibrationStore.load().contains(where: { $0.id == record.id }) {
            defaults.removeObject(forKey: checkpointKey)
            pendingRecovery = nil
        } else {
            pendingRecovery = defaults.data(forKey: checkpointKey).flatMap { try? JSONDecoder().decode(CalibrationCheckpoint.self, from: $0) }
            recoveryError = t("校准结果保存失败；恢复记录已保留")
        }
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

    /// Charge inhibition and adapter disable are independent operations.
    private func holdDischarge() {
        let controller = ChargeController.shared
        // The ceiling levers (`.bclm` pulse, and `.systemLimit` which
        // `startDrain` owns) are set by the drain phase itself; writing once and
        // verifying the read-back here would report a failure every time macOS
        // reverts or re-applies the value before the power path acts on it.
        switch controller.capabilities.strategy {
        case .ch0bch0c, .chte:
            do { try controller.setChargingAllowed(false) } catch {
                stop(reason: tf("SMC: 阻断充电失败 — {p}", error.localizedDescription))
                return
            }
        case .systemLimit, .bclm, .unavailable:
            break
        }
        guard controller.canSwitchAdapter else { return }
        if let reason = controller.beginForcedDischarge() {
            stop(reason: tf("适配器切换请求失败 — {p}", reason))
        } else {
            append(tf("已关闭适配器供电（{p}），等待实测电池放电电流", controller.activeAdapterKey ?? "SMC"))
        }
    }
    /// Hands the hardware back: adapter on first, then the charge control that
    /// this machine actually has. A machine with no charge key has nothing to
    /// restore, so it must not report a failure.
    private func releaseDischarge(limit: Int = 100) {
        chargingIssue = nil
        let controller = ChargeController.shared
        stopDrainPulse()
        controller.endForcedDischarge()
        if let error = controller.adapterRestoreError {
            chargingIssue = tf("恢复适配器供电失败 — {p}", error)
            append(chargingIssue ?? error)
            return
        }
        do {
            switch controller.capabilities.strategy {
            case .systemLimit:
                // Hand the pack back to the OS at the user's storage level: MCL
                // is what macOS itself would be holding, so nothing is left in
                // a state the system does not own.
                try controller.applyChargeLimit(limit)
            case .bclm:
                try controller.setChargingAllowed(true, targetLimit: limit)
            case .ch0bch0c, .chte:
                try controller.setChargingAllowed(true)
            case .unavailable:
                break
            }
        } catch {
            chargingIssue = tf("恢复充电控制失败 — {p}", error.localizedDescription)
            append(chargingIssue ?? error.localizedDescription)
        }
    }

    // MARK: - Stress load

    private var loadPermitted: Bool {
        ControlSafety.loadAllowed(running: isRunning, dischargePhase: phase == .discharging,
            current: signedAmperage, failed: adapterFailureLogged,
            waiting: needsUnplugForDischarge, hot: isThermalCutoffActive)
    }

    private func startStressLoad() {
        stopStressLoad()
        guard loadPermitted else { return }
        guard !needsUnplugForDischarge else { return }
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
        guard loadPermitted else { return }
        guard !needsUnplugForDischarge else { return }
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
        // Apple Silicon: one unified die, read without privileges at 1 Hz.
        if let cpu = HIDThermal.average(in: 15...110, where: { $0.lowercased().contains("tdie") }) {
            cpuTemperature = cpu
            return
        }
        // Intel: the HID page mixes CPU / GPU / PCH sensors under similar names,
        // and the SMC CPU keys proved unreliable there — TC0P read 96 °C on a
        // MacBookPro15,1 while powermetrics reported 43 °C. The privileged `smc`
        // sampler is the only source that agrees with the system, so it is used
        // instead (cached 20 s inside the helper).
        HelperClient.shared.cpuDieTemperature { [weak self] value in
            guard let self, let value, value > 10, value < 115 else { return }
            self.cpuTemperature = value
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
            // No measurement yet, or the last one went stale. Keep a labelled
            // estimate on the card instead of blanking it: "--" reads as "this
            // machine cannot tell you", which is only true when the model cannot
            // run either.
            let estimate = estimator.estimateSoC()
            socPowerWatts = estimate.watts ?? 0
            socPowerQuality = estimate.watts == nil ? .unavailable : estimate.quality
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
                guard let split else {
                    // The daemon never returned a result — usually an old helper
                    // that predates the powermetrics whitelist. Say it once,
                    // because the card itself now shows an estimate instead.
                    if !self.socPowerParseFailureLogged {
                        self.socPowerParseFailureLogged = true
                        self.append(t("SoC 功耗读取失败：特权助手没有返回 powermetrics 结果。重新安装特权助手后即可恢复实测。"))
                    }
                    return
                }
                guard split.combined > 0 else {
                    // The command ran but none of the known field names matched.
                    // Record what powermetrics actually printed, once, so the
                    // machine can be diagnosed without guessing at its format.
                    if !self.socPowerParseFailureLogged, !split.rawLines.isEmpty {
                        self.socPowerParseFailureLogged = true
                        self.append(tf("SoC 功耗解析失败，powermetrics 输出：{p}",
                                       split.rawLines.joined(separator: " ⋯ ")))
                    }
                    return
                }
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

    private func recordSplit(_ split: HelperClient.SocPowerSample,
                             processes: [ProcessLoad]) {
        splitSamples += 1
        splitCPUSum += split.cpu
        splitGPUSum += split.gpu
        splitANESum += split.ane
        guard !processes.isEmpty else { return }
        processSamples += 1
        for process in processes { processTally[process.name, default: 0] += 1 }
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
        // Automatic exports share the same allowlisted format as manual exports.
        let package = makeExport()
        let stamp = Self.fileStamp.string(from: Date())
        lastReportURL = write(exportText(package), name: "InfiniCal_Calibration_Report_\(stamp).txt")
        lastCSVURL = write(package.csv, name: "InfiniCal_Telemetry_\(stamp).csv")
        return
    }

    var hasExportSamples: Bool { !sessionPoints.isEmpty }

    private func makeExport() -> CalibrationExport {
        let timeline = phaseTimeline
        let samples = sessionPoints.compactMap { point -> CalibrationExport.Sample? in
            guard [point.percentage, point.voltage, point.amperage, point.temperature, point.power].allSatisfy({ $0.isFinite }) else { return nil }
            let samplePhase = timeline.last(where: { $0.date <= point.timestamp })?.phase ?? "unknown"
            return CalibrationExport.Sample(timestamp: point.timestamp, phase: samplePhase,
                percentage: point.percentage, voltage: point.voltage, amperage: point.amperage,
                temperature: point.temperature, power: point.power)
        }
        return CalibrationExport(schemaVersion: 1, generatedAt: Date(), completed: phase == .completed && lastCompletedRecord != nil,
            backend: ChargeController.shared.capabilities.strategy.rawValue,
            helperProtocol: HelperClient.shared.helperProtocolVersion,
            model: hardwareModel,
            capabilities: ChargeController.shared.capabilities.rawKeys.map { $0.0 },
            measuredCapacityMAh: lastCompletedRecord?.calculatedCapacityMAh,
            measuredCapacityWh: lastCompletedRecord?.calculatedCapacityWh,
            healthPercentage: lastCompletedRecord?.batteryHealthPercentage,
            sampleCount: samples.count,
            droppedSamples: exportDroppedSamples + sessionPoints.count - samples.count,
            quality: resultQuality ?? assessQuality(completed: false), conditions: lastCompletedRecord?.conditions,
            timeline: timeline, samples: samples)
    }

    private func exportText(_ package: CalibrationExport) -> String {
        let record = lastCompletedRecord
        var lines = [t("InfiniCal 电池校准分析报告"),
            "Schema=\(package.schemaVersion) · \(package.generatedAt.ISO8601Format())",
            t(package.completed ? "完整会话" : "不完整会话（不可作为完整容量测量）"),
            "Backend=\(package.backend) · Helper=\(package.helperProtocol)",
            "Samples=\(package.sampleCount) · Dropped=\(package.droppedSamples)",
            t("仅导出本次运行保留的观测样本；中断区间不补齐，缺失功耗来源不推算。"),
            tf("校准质量等级：{p}", package.quality.map { t($0.label) } ?? "--"),
            package.quality?.reasons.map { t($0) }.joined(separator: "; ") ?? "--",
            "Capacity=\(record.map { String(format: "%.0f mAh", $0.calculatedCapacityMAh) } ?? "--")",
            "SOH=\(record.map { String(format: "%.1f%%", $0.batteryHealthPercentage) } ?? "--")",
            "Discharge=\(dischargeEnergyAh) Ah · Recharge=\(rechargeEnergyAh) Ah",
            t("控制请求不等于硬件验证；实际效果请核对各阶段电流样本。")]
        lines += package.timeline.map { "\($0.date.ISO8601Format()) · \($0.phase)" }
        lines.append(t("默认脱敏：未导出序列号、用户名、路径、进程名和原始日志。"))
        return lines.joined(separator: "\n")
    }

    func exportSession(format: String) {
        guard hasExportSamples else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InfiniCal-Session." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let package = makeExport()
            if format == "json" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(package).write(to: url, options: .atomic)
            } else {
                try (format == "csv" ? package.csv : exportText(package)).write(to: url, atomically: true, encoding: .utf8)
            }
            append(t("脱敏会话导出成功"))
        } catch { chargingIssue = error.localizedDescription }
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
