import SwiftUI
import AppKit
import Darwin

/// An allowlisted diagnostic snapshot. Never serializes raw IORegistry dictionaries,
/// usernames, serial numbers, filesystem paths or command output.
struct HardwareDiagnosticReport: Codable {
    struct Row: Codable, Identifiable {
        let id: String
        let label: String
        let status: String
        let detail: String
    }
    let generatedAt: Date
    let appVersion: String
    let model: String
    let architecture: String
    let operatingSystem: String
    let rows: [Row]

    static func capture() -> HardwareDiagnosticReport {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        let result = sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = result == 0 ? String(cString: bytes) : "--"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64 (Intel or Rosetta)"
        #endif
        let helper = HelperClient.shared
        let installed = helper.refreshInstallState()
        let battery = BatteryReader.read()
        var rows: [Row] = []
        func add(_ id: String, _ label: String, _ status: String, _ detail: String) {
            rows.append(Row(id: id, label: label, status: status, detail: detail))
        }
        add("battery", "电池", battery.isPresent ? "已读取" : "未检测到",
            "FCC \(battery.maxCapacity) mAh / Design \(battery.designCapacity) mAh / Cycles \(battery.cycleCount)")
        add("power", "当前电源状态", "只读快照",
            "AC=\(battery.isPluggedIn) / Charging=\(battery.isCharging) / Current=\(String(format: "%.3f", battery.amperage)) A")
        add("helper", "特权助手", installed ? (helper.helperProtocolVersion == 3 ? "已连接" : "需要更新助手") : "未连接",
            "Protocol \(helper.helperProtocolVersion); " + helper.helperCapabilities.intersection(["ping", "info", "keys", "read", "write", "inflow", "socpower", "exec"]).sorted().joined(separator: ", "))
        add("mcl", "系统充电上限（MCL）", SystemChargeLimit.shared.isAvailable ? "已检测到接口" : "不可用",
            "80–100%; " + (SystemChargeLimit.shared.limit.map { "Current=\($0)%" } ?? "--"))
        let keys = ["BCLM", "CH0B", "CH0C", "CHTE", "CHIE", "CH0I", "CH0J"]
        let table = helper.keyInfoList(keys)
        for key in keys {
            guard let info = table[key] else {
                add(key, key, "未检测到", "--")
                continue
            }
            let expected = key == "CHTE" ? 4 : 1
            let candidate = info.isWritable && info.size == expected
            let ready = candidate && installed && helper.helperCapabilities.contains("write")
            add(key, key, ready ? "候选可用，未试写" : (candidate ? "需要更新助手" : "只读或宽度不匹配"),
                "\(info.type) / \(info.size) B / Writable=\(info.isWritable)")
        }
        #if arch(x86_64)
        add("inflow", "DisableInflow", helper.supportsInflowCommand ? "助手声明支持，未验证硬件" : "需要更新助手", "Intel / lease 15 s")
        #else
        add("inflow", "DisableInflow", "不适用", "Intel only")
        #endif
        if let countValue = try? SMC.shared.readDouble("FNum"), countValue.isFinite,
           countValue >= 0, countValue <= 10 {
            let count = Int(countValue)
            add("fans", "风扇", "已读取", "Count=\(count)")
            let modeMask = SMC.shared.keyInfo("FS! ")
            for index in 0..<count {
                let mode = SMC.shared.keyInfo("F\(index)Md")
                let target = SMC.shared.keyInfo("F\(index)Tg")
                let writableMode = (mode?.isWritable == true && mode?.size == 1)
                    || (modeMask?.isWritable == true && modeMask?.size == 2)
                let targetSupported = target?.isWritable == true
                    && ((target?.type == "flt " && target?.size == 4)
                        || (target?.type == "fpe2" && target?.size == 2))
                let ready = writableMode && targetSupported && installed && helper.helperCapabilities.contains("write")
                add("fan\(index)", "Fan \(index)", ready ? "候选可用，未试写" : "控制能力未确认",
                    "Mode=\(mode?.type ?? "--") / Target=\(target?.type ?? "--")")
            }
        } else {
            add("fans", "风扇", "读取失败", "FNum unavailable")
        }
        // Conservative sensor sampling: these are examples, not an exhaustive list.
        for key in ["TB0T", "Tp01", "TC0P", "Tg0B"] {
            let value = try? SMC.shared.readDouble(key)
            let valid = value.map { $0.isFinite && $0 > 0 && $0 < 130 } ?? false
            add("sensor-\(key)", key, valid ? "已读取" : "未检测到有效读数",
                valid ? String(format: "%.1f °C", value!) : "--")
        }
        // Control evidence describes what was asked of the hardware and what came
        // back. It never claims a physical effect the read-back did not show.
        for (index, evidence) in ControlJournal.shared.entries.prefix(12).enumerated() {
            var detail = evidence.backend
            if let target = evidence.target { detail += " · 目标 \(target)" }
            if let observed = evidence.observed { detail += " · 回读 \(observed)" }
            if let extra = evidence.detail { detail += " · \(extra)" }
            add("control-\(index)-\(evidence.operation)", evidence.operation,
                evidence.phase.label, detail)
        }
        return HardwareDiagnosticReport(generatedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--",
            model: model, architecture: architecture,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, rows: rows)
    }

    var text: String {
        let header = "InfiniCal \(appVersion)\n\(generatedAt.ISO8601Format())\n\(model) / \(architecture)\n\(operatingSystem)\n"
        return header + rows.map { "\(t($0.label)): \(t($0.status)) — \($0.detail)" }.joined(separator: "\n")
    }
}

final class HardwareDiagnosticsState: ObservableObject {
    @Published var report: HardwareDiagnosticReport?
    @Published var busy = false
    @Published var exportError: String?
}

struct HardwareDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var data = HardwareDiagnosticsState()
    @ObservedObject private var journal = ControlJournal.shared
    private var theme: Theme { Theme.current }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("硬件兼容性诊断")).font(.headline)
                Spacer()
                Button(t("刷新")) { refresh() }.disabled(data.busy)
                Button("TXT") { export(json: false) }.disabled(data.report == nil || data.busy)
                Button("JSON") { export(json: true) }.disabled(data.report == nil || data.busy)
                Button(t("关闭")) { dismiss() }
            }
            Text(t("只读探测，不试写硬件。候选可用不等于实机验证；传感器列表并非完整清单。"))
                .font(.system(size: 11)).foregroundColor(theme.textSecondary)
            if data.busy { ProgressView() }
            if !journal.entries.isEmpty {
                Text(t("最近的控制结果"))
                    .font(.system(size: 12, weight: .semibold))
                VStack(spacing: 4) {
                    ForEach(Array(journal.entries.prefix(6).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 8) {
                            Text(entry.operation)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.textSecondary)
                                .frame(width: 108, alignment: .leading)
                            Text(t(entry.phase.label))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(color(for: entry.phase))
                                .frame(width: 74, alignment: .leading)
                            Text(entry.target ?? "--")
                                .font(.system(size: 10))
                                .foregroundColor(theme.textTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.time.string(from: entry.date))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.textTertiary)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.innerControl))
                Text(t("“已回读确认”表示读回值与目标一致；“已接受”只表示写入未报错，硬件是否照做未知。"))
                    .font(.system(size: 10)).foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = data.report {
                Text("\(report.model) · \(report.architecture) · InfiniCal \(report.appVersion)")
                Text(report.operatingSystem).font(.system(size: 11))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.rows) { row in
                            Card(padding: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(t(row.label)); Spacer(); Text(t(row.status)) }
                                        .font(.system(size: 12))
                                    Text(row.detail).font(.system(size: 11)).foregroundColor(theme.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            if let exportError = data.exportError { Text(exportError).foregroundColor(theme.chartOrange) }
            Text(t("导出不包含序列号、用户名或原始 IORegistry 数据。"))
                .font(.system(size: 11)).foregroundColor(theme.textSecondary)
        }
        .padding(20).frame(width: 700, height: 620)
        .background(theme.windowBackground)
        .onAppear { refresh() }
    }

    private func color(for phase: ControlPhase) -> Color {
        switch phase {
        case .verified, .active, .restored: return theme.chartGreen
        case .accepted: return theme.chartBlue
        case .requested: return theme.textSecondary
        case .failed, .expired: return theme.chartOrange
        }
    }

    private func refresh() {
        guard !data.busy else { return }
        data.busy = true
        // Keep shared helper metadata serialized with the app's main-thread controls.
        DispatchQueue.main.async {
            data.report = HardwareDiagnosticReport.capture()
            data.busy = false
        }
    }

    private func export(json: Bool) {
        guard let report = data.report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InfiniCal-Diagnostics." + (json ? "json" : "txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(report).write(to: url, options: .atomic)
            } else {
                try report.text.write(to: url, atomically: true, encoding: .utf8)
            }
            data.exportError = nil
        } catch { data.exportError = error.localizedDescription }
    }
}
