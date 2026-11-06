//
//  DeviceProfileStore.swift
//  Runtime capture of the device profile, plus the on-disk rule archive.
//
//  This is the only file that touches hardware and the file system for the
//  capability profile. It stores one small JSON next to the other app data:
//  `~/Library/Application Support/InfiniCal/CapabilityRules.json`.
//

import Foundation
import SwiftUI
import Darwin

extension DeviceProfile {

    /// Reads the public identity of this Mac and probes what it can actually
    /// control. Read-only: nothing is written to SMC, and no identifier beyond
    /// the model code is collected.
    static func capture() -> DeviceProfile {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var modelBytes = [CChar](repeating: 0, count: max(1, size))
        let modelResult = sysctlbyname("hw.model", &modelBytes, &size, nil, 0)
        let model = modelResult == 0 ? String(cString: modelBytes) : "--"

        var brandSize = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &brandSize, nil, 0)
        var brandBytes = [CChar](repeating: 0, count: max(1, brandSize))
        let brandResult = sysctlbyname("machdep.cpu.brand_string", &brandBytes, &brandSize, nil, 0)
        let brand = brandResult == 0 ? String(cString: brandBytes) : "--"

        let battery = BatteryReader.read()
        let helper = HelperClient.shared
        let helperAvailable = helper.refreshInstallState()
        let capabilities = ChargeController.shared.detectCapabilities()

        var fanCount = 0
        if let value = try? SMC.shared.readDouble("FNum"), value.isFinite, value >= 0, value <= 10 {
            fanCount = Int(value)
        }
        var sensors: [String] = []
        for key in ["TB0T", "Tp01", "TC0P", "Tg0B"] {
            guard let value = try? SMC.shared.readDouble(key) else { continue }
            if value.isFinite && value > 0 && value < 130 { sensors.append(key) }
        }

        return DeviceProfile(model: model,
                             chip: brand,
                             family: ChipFamily.classify(brand),
                             macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                             chargeStrategy: capabilities.strategy.rawValue,
                             helperAvailable: helperAvailable,
                             fanCount: fanCount,
                             hasBattery: battery.isPresent,
                             sensorKeys: sensors)
    }

    var backendTitle: String {
        ChargeStrategy(rawValue: chargeStrategy)?.title ?? t("不可用")
    }
}

/// Keeps the rule archive on disk. The previous library is retained so a bad
/// import can be undone without reinstalling the app.
final class DeviceProfileStore: ObservableObject {

    static let shared = DeviceProfileStore()

    @Published private(set) var archive: CapabilityRuleArchive
    @Published private(set) var message: String?

    private let directory: URL
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InfiniCal", isDirectory: true)
        self.directory = base
        self.fileURL = base.appendingPathComponent("CapabilityRules.json")
        self.archive = Self.load(from: base.appendingPathComponent("CapabilityRules.json")) ?? .bundled
    }

    var library: CapabilityRuleLibrary { archive.current }
    var canRollBack: Bool { archive.previous != nil }

    func assess(_ profile: DeviceProfile) -> CapabilityAssessment {
        library.assess(profile)
    }

    /// Imports a rule library from a JSON file. The file must contain a bare
    /// library (`version`, `updated`, `rules`); an archive file is rejected so
    /// a stale `previous` cannot overwrite the rollback slot.
    func install(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let library = try JSONDecoder().decode(CapabilityRuleLibrary.self, from: data)
        if let error = library.validationError {
            throw CapabilityRuleError.invalid(error)
        }
        archive = archive.installing(library)
        try save()
        message = tf("已导入规则库 v{p}", "\(library.version)")
    }

    func rollback() throws {
        guard let next = archive.rollingBack() else {
            throw CapabilityRuleError.invalid(t("没有可回滚的规则库版本"))
        }
        archive = next
        try save()
        message = tf("已回滚到规则库 v{p}", "\(next.current.version)")
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> CapabilityRuleArchive? {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(CapabilityRuleArchive.self, from: data),
              archive.current.validationError == nil else { return nil }
        return archive
    }
}

enum CapabilityRuleError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        }
    }
}
