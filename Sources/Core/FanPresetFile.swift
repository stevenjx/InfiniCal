//
//  FanPresetFile.swift
//  Sharing a fan curve, without sharing a machine.
//
//  `FanPreset` was already `Codable`; what was missing was a file, a version
//  and the validation that makes a foreign file safe to apply. Two things can
//  go wrong when a preset comes from another Mac:
//
//    • it names a sensor this machine does not have — applying it silently
//      would fall back to the built-in sensor and look like the curve working;
//    • it names a fan index this machine does not have — same story.
//
//  Both are reported, and the sensor case falls back to the hottest available
//  one so the curve still does something useful.
//

import Foundation

/// The on-disk form. A wrapper rather than a bare `FanPreset` so a future
/// version can carry more than one preset or a comment without guessing what
/// an older file meant.
struct FanPresetDocument: Codable, Equatable {
    var format: String = FanPresetDocument.currentFormat
    var version: Int = 1
    var exportedAt: Date = Date()
    var appVersion: String = ""
    var presets: [FanPreset]

    static let currentFormat = "infinical.fanpresets"

    static func make(presets: [FanPreset],
                     appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") -> FanPresetDocument {
        FanPresetDocument(exportedAt: Date(), appVersion: appVersion, presets: presets)
    }
}

enum FanPresetImportError: Error, Equatable {
    case notAFanPresetFile
    case unsupportedVersion(Int)
    case empty
    case noUsablePreset
    case unreadable

    var message: String {
        switch self {
        case .notAFanPresetFile: return t("这不是 InfiniCal 的风扇预设文件")
        case .unsupportedVersion(let value): return tf("预设文件版本 {p} 比当前版本新，请先更新 InfiniCal", "\(value)")
        case .empty: return t("预设文件里没有预设")
        case .noUsablePreset: return t("预设与本机风扇不兼容，没有可以导入的内容")
        case .unreadable: return t("预设文件无法读取")
        }
    }
}

/// What actually happened to one preset, in the user's language.
struct FanPresetImportResult: Equatable {
    var imported: [FanPreset] = []
    /// Presets that named a missing sensor and were re-pointed.
    var sensorFallbacks: [String] = []
    /// Presets whose fan indices do not exist here; imported as-is minus the
    /// missing fans, because a 2-fan preset on a 1-fan Mac is still mostly right.
    var trimmedFans: [String] = []
    var skipped: [String] = []
    /// The sensor the fallback chose, for the message.
    var fallbackSensor: String?

    var summary: String? {
        guard !imported.isEmpty || !sensorFallbacks.isEmpty || !trimmedFans.isEmpty else { return nil }
        var parts: [String] = []
        if !imported.isEmpty { parts.append(tf("已导入 {p} 个预设", "\(imported.count)")) }
        if !sensorFallbacks.isEmpty {
            parts.append(tf("{p} 个预设使用了本机没有的温度传感器，已改用 {p}",
                            "\(sensorFallbacks.count)", fallbackSensor ?? t("本机最热的传感器")))
        }
        if !trimmedFans.isEmpty {
            parts.append(tf("{p} 个预设包含本机不存在的风扇，已按本机风扇数裁剪", "\(trimmedFans.count)"))
        }
        if !skipped.isEmpty {
            parts.append(tf("{p} 个预设无法使用", "\(skipped.count)"))
        }
        return parts.joined(separator: "；")
    }
}

enum FanPresetIO {

    static func encode(_ document: FanPresetDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) -> Result<FanPresetDocument, FanPresetImportError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(FanPresetDocument.self, from: data) else {
            return .failure(.notAFanPresetFile)
        }
        guard document.format == FanPresetDocument.currentFormat else {
            return .failure(.notAFanPresetFile)
        }
        guard document.version <= 1 else { return .failure(.unsupportedVersion(document.version)) }
        guard !document.presets.isEmpty else { return .failure(.empty) }
        return .success(document)
    }

    /// Validates every preset against the hardware this Mac actually has.
    ///
    /// Pure: the caller passes the fan count and the sensor keys. That is what
    /// makes "a preset from another Mac" testable without another Mac.
    static func validate(_ presets: [FanPreset],
                         fanCount: Int,
                         sensorKeys: [String],
                         fallbackSensor: String?) -> FanPresetImportResult {
        var result = FanPresetImportResult()
        for preset in presets {
            var copy = preset
            var usable = true

            // Fans: keep the ones that exist, drop the rest. A preset for a
            // 2-fan machine on a 1-fan Mac still describes the first fan.
            let validIndices = Set(0..<max(0, fanCount))
            let keptModes = copy.modes.filter { validIndices.contains($0.key) }
            let keptRPMs = copy.rpms.filter { validIndices.contains($0.key) }
            if keptModes.isEmpty {
                usable = false
            }
            if keptModes.count != copy.modes.count || keptRPMs.count != copy.rpms.count {
                result.trimmedFans.append(preset.name)
            }
            copy.modes = keptModes
            copy.rpms = keptRPMs

            // Sensor: a curve pointed at a key this machine does not expose is
            // the dangerous case, because it silently reads 0 °C and the fan
            // never spins up. Re-point it and say so.
            if let key = copy.curveSensorKey, !key.isEmpty, !sensorKeys.contains(key) {
                result.sensorFallbacks.append(preset.name)
                copy.curveSensorKey = fallbackSensor
                result.fallbackSensor = fallbackSensor
            } else if let key = copy.curveSensorKey, key.isEmpty {
                copy.curveSensorKey = fallbackSensor
            }

            if usable {
                result.imported.append(copy)
            } else {
                result.skipped.append(preset.name)
            }
        }
        return result
    }

    /// Merge rule: same name replaces, different name appends. Importing the
    /// same file twice therefore changes nothing, which is what people expect
    /// from a file they already imported.
    static func merge(_ incoming: [FanPreset], into existing: [FanPreset]) -> (result: [FanPreset], replaced: Int, added: Int) {
        var result = existing
        var replaced = 0, added = 0
        for preset in incoming {
            if let index = result.firstIndex(where: { $0.name == preset.name }) {
                result[index] = preset
                replaced += 1
            } else {
                result.append(preset)
                added += 1
            }
        }
        return (result, replaced, added)
    }
}