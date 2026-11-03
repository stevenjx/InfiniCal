//
//  SparkleUpdater.swift
//  Sparkle 2 auto-update, wired into the app's existing safety barrier.
//
//  Why this exists
//  ---------------
//  Sparkle owns the whole update pipeline: fetch the appcast, download, verify
//  the EdDSA signature on the archive, stage the bundle, relaunch. What it does
//  not know about is this app's hardware state — a calibration session, a fan
//  curve, a charge ceiling. Those must be handed back before the process exits,
//  so installation is gated on the same `prepareForUpdate()` the manual flow
//  used.
//
//  Signature model: the app is ad-hoc signed, which Sparkle accepts as the
//  minimum ("If no Apple Code Signing certificate is available, adhoc signing
//  can be used at minimum"). Trust comes from `SUPublicEDKey`: every archive is
//  signed with the EdDSA private key held in the login keychain, and the public
//  half ships in Info.plist. `SUUpdateValidator` passes when either the EdDSA
//  signature or the Apple code signature matches, so this works without a
//  Developer ID.
//

import Foundation
import AppKit
import Sparkle

@MainActor
final class SparkleUpdater: NSObject, ObservableObject {

    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController!
    private var isLoadingSettings = false

    /// Version string of an update Sparkle found and is offering.
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var lastError: String?

    /// Whether Sparkle checks on its own schedule. Sparkle persists this in the
    /// app's defaults domain, so reloading it is only for the first mirror.
    @Published var automaticallyChecks: Bool = false {
        didSet {
            guard !isLoadingSettings else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Read live from Sparkle rather than mirrored: it flips this during a
    /// session and the check button only needs the value when it redraws.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    private override init() {
        super.init()
        // startingUpdater: true lets Sparkle begin scheduling immediately; the
        // actual cadence is governed by automaticallyChecksForUpdates below.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: nil)
        isLoadingSettings = true
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        isLoadingSettings = false
        lastCheckDate = controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        lastError = nil
        controller.checkForUpdates(nil)
    }

    /// Used at launch and from the menu bar: no window if nothing is found.
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }
}

// MARK: - Safety gate

extension SparkleUpdater: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        lastCheckDate = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckDate = updater.lastUpdateCheckDate
        if let error { lastError = error.localizedDescription }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        lastError = error.localizedDescription
    }

    /// Refuse to even download while the pack is under a calibration session:
    /// the run owns the charge hardware and a relaunch would abandon it.
    func updater(_ updater: SPUUpdater,
                 shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard !CalibrationEngine.shared.isRunning, !CalibrationEngine.shared.needsRecovery else {
            throw NSError(domain: "InfiniCal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: t("校准或恢复处理中，请先结束校准并完成安全清理后再更新。")
            ])
        }
    }

    /// The last moment before Sparkle quits and replaces the bundle: hand the
    /// fans and the charge path back so the outgoing process leaves no hardware
    /// pinned at a value the new build did not choose.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        if let error = AppState.shared.prepareForUpdate() {
            lastError = error
        }
    }
}
