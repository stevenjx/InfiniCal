//
//  ChargeController.swift
//  SMC charging control + the privileged helper bridge.
//
//  Capability detection is done at runtime by asking the SMC which keys exist
//  and whether they are writable. Nothing is assumed about the chip family:
//  the controller always reports the mechanism it is actually using.
//

import Foundation
import Darwin

enum ChargeStrategy: String {
    case bclm          // Apple Silicon: BCLM holds the maximum charge level
    case ch0bch0c      // Intel / T2: CH0B + CH0C inhibit charging
    case chie          // Newer Apple Silicon: CHIE charging-inhibit flag
    case unavailable

    var title: String {
        switch self {
        case .bclm: return t("BCLM（充电上限）")
        case .ch0bch0c: return t("CH0B / CH0C（充电禁止）")
        case .chie: return t("CHIE（充电禁止标志）")
        case .unavailable: return t("不可用")
        }
    }
}

struct ChargeCapabilities {
    var strategy: ChargeStrategy = .unavailable
    var bclm: SMCKeyInfo?
    var ch0b: SMCKeyInfo?
    var ch0c: SMCKeyInfo?
    var ch0i: SMCKeyInfo?
    var chie: SMCKeyInfo?
    var aclc: SMCKeyInfo?
    var hasHelper: Bool = false
    var rawKeys: [(String, String)] = []


    var summary: String {
        switch strategy {
        case .bclm: return t("通过 BCLM 直接设置充电上限")
        case .ch0bch0c: return t("通过 CH0B/CH0C 禁止充电，由守护进程按阈值控制")
        case .chie: return t("通过 CHIE 禁止充电，由守护进程按阈值控制")
        case .unavailable: return t("此机型未暴露可写的充电控制键")
        }
    }
}

enum HelperError: LocalizedError {
    case notInstalled
    case noResponse(String)
    case smc(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return t("需要安装特权助手才能写入 SMC")
        case .noResponse(let detail): return tf("特权助手无响应：{p}", detail)
        case .smc(let detail): return tf("SMC 操作失败：{p}", detail)
        }
    }
}

final class HelperClient {

    static let shared = HelperClient()

    static let socketPath = "/var/run/com.infinitycomputer.infinical.helper.sock"
    static let helperPath = "/Library/PrivilegedHelperTools/com.infinitycomputer.infinical.helper"
    static let plistPath = "/Library/LaunchDaemons/com.infinitycomputer.infinical.helper.plist"
    static let label = "com.infinitycomputer.infinical.helper"

    /// The daemon shipped under the previous app name. Left running, it would
    /// keep a socket open and fight the new helper for the same SMC keys, so it
    /// is removed during installation.
    static let legacyLabel = "com.aibattery.helper"
    static let legacyHelperPath = "/Library/PrivilegedHelperTools/com.aibattery.helper"
    static let legacyPlistPath = "/Library/LaunchDaemons/com.aibattery.helper.plist"
    static let legacySocketPath = "/var/run/com.aibattery.helper.sock"

    private(set) var lastKnownInstalled = false

    var bundledHelperPath: String {
        Bundle.main.bundlePath + "/Contents/Library/Helper/com.infinitycomputer.infinical.helper"
    }

    func ping() -> Bool {
        guard let response = request(["cmd": "ping"], timeout: 1.0) else { return false }
        return (response["ok"] as? Bool) ?? false
    }

    func refreshInstallState() -> Bool {
        let exists = FileManager.default.fileExists(atPath: HelperClient.helperPath)
        lastKnownInstalled = exists && ping()
        return lastKnownInstalled
    }

    func request(_ payload: [String: Any], timeout: TimeInterval = 2.0) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(HelperClient.socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in pathBytes.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { return nil }

        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { return nil }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }
        }
        guard !buffer.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else { return nil }
        return object
    }

    // MARK: - Install / remove

    /// Installs the daemon. Requires a single administrator prompt.
    func install() throws {
        let source = bundledHelperPath
        guard FileManager.default.fileExists(atPath: source) else {
            throw HelperError.noResponse(t("安装包内缺少助手可执行文件"))
        }
        let uid = getuid()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(HelperClient.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperClient.helperPath)</string>
                <string>--uid</string>
                <string>\(uid)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardErrorPath</key><string>/var/log/com.infinitycomputer.infinical.helper.log</string>
        </dict>
        </plist>
        """
        let tempPlist = NSTemporaryDirectory() + "com.infinitycomputer.infinical.helper.plist"
        try plist.write(toFile: tempPlist, atomically: true, encoding: .utf8)

        let script = """
        #!/bin/sh
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        /bin/cp "\(source)" "\(HelperClient.helperPath)"
        /usr/sbin/chown root:wheel "\(HelperClient.helperPath)"
        /bin/chmod 755 "\(HelperClient.helperPath)"
        /bin/cp "\(tempPlist)" "\(HelperClient.plistPath)"
        /usr/sbin/chown root:wheel "\(HelperClient.plistPath)"
        /bin/chmod 644 "\(HelperClient.plistPath)"
        # Retire the daemon installed under the previous app name.
        /bin/launchctl bootout system/\(HelperClient.legacyLabel) 2>/dev/null || true
        /bin/rm -f "\(HelperClient.legacyPlistPath)" "\(HelperClient.legacyHelperPath)" "\(HelperClient.legacySocketPath)"
        /bin/launchctl bootout system/\(HelperClient.label) 2>/dev/null || true
        /bin/launchctl bootstrap system "\(HelperClient.plistPath)"
        """
        let scriptPath = NSTemporaryDirectory() + "install-infinical-helper.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let appleScript = "do shell script \"/bin/sh \(scriptPath)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw HelperError.noResponse(errorInfo[NSAppleScript.errorMessage] as? String ?? t("授权失败"))
        }
        // Give launchd a moment to start the daemon.
        for _ in 0..<20 {
            if ping() { lastKnownInstalled = true; return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw HelperError.noResponse(t("助手已安装但未能启动"))
    }


    // MARK: - Operations

    /// Key table queried through the root daemon (falls back to local reads).
    func keyInfoList(_ keys: [String]) -> [String: SMCKeyInfo] {
        var result: [String: SMCKeyInfo] = [:]
        if lastKnownInstalled,
           let response = request(["cmd": "info", "keys": keys]),
           (response["ok"] as? Bool) == true,
           let rows = response["keys"] as? [[String: Any]] {
            for row in rows {
                guard let key = row["key"] as? String, (row["exists"] as? Bool) == true else { continue }
                result[key] = SMCKeyInfo(size: UInt32((row["size"] as? Int) ?? 0),
                                         type: (row["type"] as? String) ?? "",
                                         attributes: UInt8(clamping: (row["attrs"] as? Int) ?? 0))
            }
            return result
        }
        for key in keys {
            if let info = SMC.shared.keyInfo(key) { result[key] = info }
        }
        return result
    }

    func smcWrite(_ key: String, _ value: UInt8) throws {
        if SMC.shared.keyInfo(key) != nil, geteuid() == 0 {
            try SMC.shared.writeUInt8(key, value)
            return
        }
        guard lastKnownInstalled else { throw HelperError.notInstalled }
        let hex = String(format: "%02x", value)
        guard let response = request(["cmd": "write", "key": key, "bytes": hex]) else {
            throw HelperError.noResponse(tf("写入 {p} 超时", key))
        }
        guard (response["ok"] as? Bool) == true else {
            throw HelperError.smc((response["error"] as? String) ?? t("未知错误"))
        }
    }

    /// Writes an arbitrary-width payload. Fan targets are `flt` (4 bytes), so the
    /// single-byte helper above cannot express them.
    func smcWriteBytes(_ key: String, _ bytes: [UInt8]) throws {
        if SMC.shared.keyInfo(key) != nil, geteuid() == 0 {
            try SMC.shared.writeBytes(key, bytes)
            return
        }
        guard lastKnownInstalled else { throw HelperError.notInstalled }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let response = request(["cmd": "write", "key": key, "bytes": hex]) else {
            throw HelperError.noResponse(tf("写入 {p} 超时", key))
        }
        guard (response["ok"] as? Bool) == true else {
            throw HelperError.smc((response["error"] as? String) ?? t("未知错误"))
        }
    }

    /// CPU + GPU + ANE power straight from powermetrics (root only).
    func socPower() -> Double? {
        guard lastKnownInstalled,
              let response = request(["cmd": "socpower"], timeout: 8),
              (response["ok"] as? Bool) == true,
              let watts = response["soc"] as? Double,
              watts > 0, watts < 200 else { return nil }
        return watts
    }

    /// Same measurement as `socPower()`, but keeps the per-block breakdown.
    ///
    /// Runs powermetrics through the existing `exec` whitelist instead of the
    /// dedicated command, so the daemon binary is unchanged. Output format,
    /// verified on macOS 26 / M2 Pro:
    ///     CPU Power: 2504 mW
    ///     GPU Power: 939 mW
    ///     ANE Power: 0 mW
    ///     Combined Power (CPU + GPU + ANE): 3443 mW
    struct SocPowerSample {
        var cpu: Double
        var gpu: Double
        var ane: Double
        var combined: Double
        /// The power lines of the raw sampler output. Kept so a machine whose
        /// field names differ can be diagnosed from the log instead of guessed
        /// at, and so `combined == 0` is distinguishable from "no response".
        var rawLines: [String]
    }

    func socPowerSplit() -> SocPowerSample? {
        guard lastKnownInstalled,
              let response = request(["cmd": "exec",
                                      "path": "/usr/bin/powermetrics",
                                      "args": ["--samplers", "cpu_power", "-n", "1", "-i", "400"]],
                                     timeout: 8),
              (response["ok"] as? Bool) == true,
              let output = response["output"] as? String else { return nil }

        var cpu = 0.0, gpu = 0.0, ane = 0.0, combined = 0.0
        var rawLines: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().contains("power") else { continue }
            if rawLines.count < 8 { rawLines.append(line) }
            if line.hasPrefix("CPU Power:") { cpu = Self.watts(line) }
            else if line.hasPrefix("GPU Power:") { gpu = Self.watts(line) }
            else if line.hasPrefix("ANE Power:") { ane = Self.watts(line) }
            else if line.contains("Combined Power") { combined = Self.watts(line) }
            // Intel reports the package total rather than CPU + GPU + ANE.
            else if line.hasPrefix("Package Power:") { combined = Self.watts(line) }
        }
        guard combined > 0 || cpu > 0 else {
            return SocPowerSample(cpu: 0, gpu: 0, ane: 0, combined: 0, rawLines: rawLines)
        }
        return SocPowerSample(cpu: cpu, gpu: gpu, ane: ane,
                              combined: combined > 0 ? combined : cpu + gpu + ane,
                              rawLines: rawLines)
    }

    /// "CPU Power: 2504 mW" → 2.504
    private static func watts(_ line: String) -> Double {
        let digits = line.compactMap { $0.isNumber ? $0 : nil }
        guard !digits.isEmpty, let value = Double(String(digits)) else { return 0 }
        return line.contains("mW") ? value / 1000 : value
    }

    private var dieTempFetchInFlight = false
    private var dieTempCache: Double?
    private var lastDieTempFetch = Date.distantPast

    /// CPU die temperature from the privileged `smc` sampler — the same
    /// quantity `powermetrics` prints as "CPU die temperature".
    ///
    /// The sampler only exists on Intel: on Apple Silicon powermetrics rejects
    /// it ("unrecognized sampler: smc"), so callers there keep their HID
    /// reading. One call costs ~1.4 s of a core, so results are cached for
    /// 20 s and the fetch runs off the main thread. Main thread only.
    func cpuDieTemperature(_ completion: @escaping (Double?) -> Void) {
        guard lastKnownInstalled else { completion(nil); return }
        if let cached = dieTempCache, Date().timeIntervalSince(lastDieTempFetch) < 20 {
            completion(cached)
            return
        }
        guard !dieTempFetchInFlight else { return }
        dieTempFetchInFlight = true
        lastDieTempFetch = Date()
        DispatchQueue.global(qos: .utility).async {
            let value = self.fetchDieTemperature()
            DispatchQueue.main.async {
                self.dieTempFetchInFlight = false
                if let value {
                    self.dieTempCache = value
                    self.lastDieTempFetch = Date()
                }
                completion(value)
            }
        }
    }

    private func fetchDieTemperature() -> Double? {
        guard let response = request(["cmd": "exec",
                                      "path": "/usr/bin/powermetrics",
                                      "args": ["--samplers", "smc", "-n", "1", "-i", "500"]],
                                     timeout: 8),
              (response["ok"] as? Bool) == true,
              let output = response["output"] as? String else { return nil }
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("CPU die temperature:") else { continue }
            let value = line.dropFirst("CPU die temperature:".count)
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first
                .flatMap { Double($0) }
            if let value, value > 0, value < 120 { return value }
        }
        return nil
    }

    func runPrivileged(_ path: String, _ arguments: [String]) throws -> String {
        guard lastKnownInstalled else { throw HelperError.notInstalled }
        guard let response = request(["cmd": "exec", "path": path, "args": arguments], timeout: 6) else {
            throw HelperError.noResponse(tf("执行 {p} 超时", path))
        }
        guard (response["ok"] as? Bool) == true else {
            throw HelperError.smc((response["error"] as? String) ?? t("未知错误"))
        }
        return (response["output"] as? String) ?? ""
    }
}

final class ChargeController {

    static let shared = ChargeController()

    private(set) var capabilities = ChargeCapabilities()

    func detectCapabilities() -> ChargeCapabilities {
        var caps = ChargeCapabilities()
        caps.hasHelper = HelperClient.shared.lastKnownInstalled
        let table = HelperClient.shared.keyInfoList(["BCLM", "CH0B", "CH0C", "CH0I", "CHIE", "ACLC"])
        caps.bclm = table["BCLM"]
        caps.ch0b = table["CH0B"]
        caps.ch0c = table["CH0C"]
        caps.ch0i = table["CH0I"]
        caps.chie = table["CHIE"]
        caps.aclc = table["ACLC"]

        if let bclm = caps.bclm, bclm.isWritable {
            caps.strategy = .bclm
        } else if caps.ch0b != nil {
            caps.strategy = .ch0bch0c
        } else if let chie = caps.chie, chie.isWritable {
            caps.strategy = .chie
        } else {
            caps.strategy = .unavailable
        }

        var rows: [(String, String)] = []
        for key in ["BCLM", "CH0B", "CH0C", "CH0I", "CHIE", "ACLC", "TB0T", "B0AC", "B0AV", "B0FC"] {
            if let info = table[key] ?? SMC.shared.keyInfo(key) {
                let value = (try? SMC.shared.readDouble(key)) ?? 0
                rows.append((key, "\(info.type) · \(String(format: "%.2f", value))"))
            } else {
                rows.append((key, t("不存在")))
            }
        }
        caps.rawKeys = rows
        capabilities = caps
        return caps
    }

    /// Sets the charge limit. `100` means "no limit".
    func applyChargeLimit(_ percent: Int) throws {
        let clamped = max(0, min(100, percent))
        switch capabilities.strategy {
        case .bclm:
            try HelperClient.shared.smcWrite("BCLM", UInt8(clamped))
        case .ch0bch0c:
            // Handled by the software loop in AppState.
            break
        case .chie:
            break
        case .unavailable:
            throw HelperError.smc(t("此机型未暴露充电限制键"))
        }
    }

    func setChargingAllowed(_ allowed: Bool) throws {
        switch capabilities.strategy {
        case .bclm:
            // BCLM is authoritative on Apple Silicon; 100 restores full charging.
            if !allowed {
                let current = BatteryReader.read().percentage
                try HelperClient.shared.smcWrite("BCLM", UInt8(max(0, min(100, current))))
            }
        case .ch0bch0c:
            let value: UInt8 = allowed ? 0x00 : 0x02
            if capabilities.ch0b != nil { try HelperClient.shared.smcWrite("CH0B", value) }
            if capabilities.ch0c != nil { try HelperClient.shared.smcWrite("CH0C", value) }
        case .chie:
            try HelperClient.shared.smcWrite("CHIE", allowed ? 0x00 : 0x01)
        case .unavailable:
            throw HelperError.smc(t("此机型未暴露充电控制键"))
        }
    }

    /// Raw ACLC value captured before a forced discharge, restored afterwards.
    private var savedAdapterCurrentLimit: [UInt8]?

    /// Makes the Mac run off the battery while the adapter stays connected.
    ///
    /// Intel has no BCLM, and CH0B/CH0C only inhibit charging — the machine
    /// keeps drawing from the adapter at 0 A, which is why a discharge phase
    /// never progresses there. `ACLC` is the adapter current limit: with it at
    /// zero the PMU has to source the load from the pack.
    ///
    /// The original bytes are captured first and written back verbatim on
    /// release, so the exact type and value never have to be assumed. A crash
    /// mid-session leaves the limit at zero until the next boot clears it, which
    /// is the same trade-off every charge-limiter makes.
    ///
    /// Returns false when the key is absent or not writable, so the caller can
    /// fall back to asking the user to unplug.
    @discardableResult
    func beginForcedDischarge() -> Bool {
        guard savedAdapterCurrentLimit == nil else { return true }
        guard let aclc = capabilities.aclc, aclc.isWritable else { return false }
        guard let (_, raw) = try? SMC.shared.readBytes("ACLC"), !raw.isEmpty else { return false }
        let zeroed = [UInt8](repeating: 0, count: raw.count)
        guard (try? HelperClient.shared.smcWriteBytes("ACLC", zeroed)) != nil else { return false }
        // Read back rather than trusting the write: a key can accept a write and
        // silently ignore it.
        guard let (_, check) = try? SMC.shared.readBytes("ACLC"), check == zeroed else { return false }
        savedAdapterCurrentLimit = raw
        return true
    }

    func endForcedDischarge() {
        guard let raw = savedAdapterCurrentLimit else { return }
        savedAdapterCurrentLimit = nil
        _ = try? HelperClient.shared.smcWriteBytes("ACLC", raw)
    }

    /// True when BCLM is holding a ceiling below full.    ///
    /// That is InfiniCal's own normal state — the charge-limit feature — and
    /// `start()` lifts it, so the calibration gate must not report it as a
    /// system limit.
    ///
    /// The inhibit flags (CHIE / CH0B / CH0C) are deliberately *not* excluded.
    /// Outside a session this app leaves them cleared on every exit path, so an
    /// inhibit that is set belongs to something else (another charge-limiter
    /// tool, for instance) and does block a run.
    static func hasChargeCeiling() -> Bool {
        guard let limit = try? SMC.shared.readDouble("BCLM") else { return false }
        return limit < 99.5
    }

    enum LowPowerMode: Int {
        case off = 0, on = 1, batteryOnly = 2, adapterOnly = 3
    }

    func setLowPowerMode(_ mode: LowPowerMode) throws {
        switch mode {
        case .off, .on:
            _ = try HelperClient.shared.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "\(mode.rawValue)"])
        case .batteryOnly:
            _ = try HelperClient.shared.runPrivileged("/usr/bin/pmset", ["-b", "lowpowermode", "1"])
            _ = try HelperClient.shared.runPrivileged("/usr/bin/pmset", ["-c", "lowpowermode", "0"])
        case .adapterOnly:
            _ = try HelperClient.shared.runPrivileged("/usr/bin/pmset", ["-c", "lowpowermode", "1"])
            _ = try HelperClient.shared.runPrivileged("/usr/bin/pmset", ["-b", "lowpowermode", "0"])
        }
    }
}
