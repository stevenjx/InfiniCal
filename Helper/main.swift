//
//  main.swift  (InfiniCalHelper)
//  Root daemon: the only process allowed to write SMC keys.
//
//  Security model:
//    • installed with one explicit admin prompt into /Library/PrivilegedHelperTools
//    • unix socket /var/run/com.infinitycomputer.infinical.helper.sock, owner = installing user, mode 0600
//    • only whitelisted commands, only whitelisted executables
//

import Foundation
import Darwin
import IOKit.pwr_mgt

// Intel-only inflow request. Each renewal replaces a 15-second assertion;
// powerd releases it even if the UI disappears or stops renewing the lease.
// A successful API return is not proof of negative battery current.
let inflowLock = NSLock()
var inflowAssertion: IOPMAssertionID?

func setInflowDisabled(_ disabled: Bool) -> [String: Any] {
    inflowLock.lock(); defer { inflowLock.unlock() }
    if !disabled {
        if let id = inflowAssertion {
            let result = IOPMAssertionRelease(id)
            // A lease can already have expired and released itself.
            if result != kIOReturnSuccess && result != kIOReturnNotFound {
                return ["ok": false, "error": "DisableInflow release: \(result)"]
            }
            inflowAssertion = nil
        }
        return ["ok": true]
    }
    #if arch(x86_64)
    var created: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithDescription(
        "DisableInflow" as CFString,
        "InfiniCal: Intel discharge lease" as CFString,
        nil, nil, nil, 15,
        kIOPMAssertionTimeoutActionRelease as CFString, &created)
    guard result == kIOReturnSuccess else {
        return ["ok": false, "error": "DisableInflow create: \(result)"]
    }
    if let old = inflowAssertion { IOPMAssertionRelease(old) }
    inflowAssertion = created
    return ["ok": true, "leaseSeconds": 15]
    #else
    return ["ok": false, "error": "DisableInflow backend is Intel-only"]
    #endif
}

var socketPath = "/var/run/com.infinitycomputer.infinical.helper.sock"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var ownerUID: uid_t = 0
let args = Array(CommandLine.arguments.dropFirst())
if let index = args.firstIndex(of: "--uid"), index + 1 < args.count, let uid = uid_t(args[index + 1]) {
    ownerUID = uid
}
if let index = args.firstIndex(of: "--socket"), index + 1 < args.count {
    socketPath = args[index + 1]
}

let helperProtocolVersion = 3
let helperCapabilities: [String] = ["ping", "info", "keys", "read", "write", "inflow", "socpower", "exec"]
let maxRequestBytes = 64 * 1024
let maxResponseBytes = 256 * 1024

// Only these SMC families are written by the app. Unknown keys remain readable
// for diagnostics but cannot become an arbitrary root write primitive.
func isAllowedWriteKey(_ key: String) -> Bool {
    guard key.count == 4, key.unicodeScalars.allSatisfy({ $0.value < 128 }) else { return false }
    if ["BCLM", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "CHTE", "FS! "].contains(key) { return true }
    if key.hasPrefix("F"), key.count == 4, key[key.index(after: key.startIndex)].isNumber {
        return key.hasSuffix("Md") || key.hasSuffix("Tg")
    }
    return false
}

func isSafeExec(_ path: String, _ arguments: [String]) -> Bool {
    switch path {
    case "/usr/bin/powermetrics":
        let allowed = [
            ["--samplers", "cpu_power", "-n", "1", "-i", "400"],
            ["--samplers", "smc", "-n", "1", "-i", "500"]
        ]
        return allowed.contains(arguments)
    case "/usr/bin/pmset":
        guard arguments.count == 4,
              arguments[0] == "-a" || arguments[0] == "-b" || arguments[0] == "-c",
              arguments[1] == "lowpowermode",
              arguments[2] == "0" || arguments[2] == "1" else { return false }
        return arguments[0] == "-a" || arguments.count == 4
    default:
        return false
    }
}

let allowedExecutables: Set<String> = ["/usr/bin/pmset", "/usr/bin/powermetrics"]

let smc = SMC.shared

func handle(_ request: [String: Any]) -> [String: Any] {
    let command = (request["cmd"] as? String) ?? ""
    switch command {
    case "ping":
        return ["ok": true, "version": helperProtocolVersion,
                "capabilities": helperCapabilities,
                "pid": ProcessInfo.processInfo.processIdentifier]

    case "inflow":
        guard let disabled = request["disabled"] as? Bool else {
            return ["ok": false, "error": "bad inflow request"]
        }
        return setInflowDisabled(disabled)

    case "info":
        guard let keys = request["keys"] as? [String], keys.count <= 64 else {
            return ["ok": false, "error": "bad keys"]
        }
        var rows: [[String: Any]] = []
        for key in keys where key.count == 4 && key.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            if let info = smc.keyInfo(key) {
                let value = (try? smc.readDouble(key)) ?? 0
                rows.append(["key": key, "exists": true, "type": info.type,
                             "size": info.size, "attrs": Int(info.attributes), "value": value])
            } else {
                rows.append(["key": key, "exists": false])
            }
        }
        return ["ok": true, "keys": rows]

    case "keys":
        // `count` comes from #KEY so a failed enumeration is visible: if the
        // returned list is shorter, the index-read offset is wrong.
        let names = smc.allKeys()
        return ["ok": true, "count": smc.keyCount() ?? -1, "found": names.count, "keys": names]

    case "read":
        guard let key = request["key"] as? String, key.count == 4,
              key.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            return ["ok": false, "error": "bad key"]
        }
        do {
            let (info, bytes) = try smc.readBytes(key)
            let value = (try? SMC.decode(info: info, bytes: bytes)) ?? 0
            return ["ok": true, "type": info.type, "size": info.size,
                    "bytes": bytes.map { String(format: "%02x", $0) }.joined(),
                    "value": value]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

    case "write":
        guard let key = request["key"] as? String, key.count == 4,
              isAllowedWriteKey(key),
              let hex = request["bytes"] as? String,
              hex.count <= 64,
              hex.count % 2 == 0 else {
            return ["ok": false, "error": "write key or payload not allowed"]
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return ["ok": false, "error": "bad hex"]
            }
            bytes.append(byte)
            index = next
        }
        guard let info = smc.keyInfo(key), info.isWritable,
              bytes.count == Int(info.size) else {
            return ["ok": false, "error": "key is missing, read-only, or wrong width"]
        }
        do {
            try smc.writeBytes(key, bytes)
            return ["ok": true]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

    case "socpower":
        // powermetrics is root-only; the daemon is the only process allowed to call it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["--samplers", "cpu_power", "-n", "1", "-i", "400"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            // "Combined Power (CPU + GPU + ANE): 1234 mW"
            for line in text.split(separator: "\n") {
                guard line.contains("Combined Power") else { continue }
                let digits = line.compactMap { $0.isNumber ? $0 : nil }
                guard !digits.isEmpty, let value = Double(String(digits)) else { continue }
                let watts = line.contains("mW") ? value / 1000.0 : value
                return ["ok": true, "soc": watts]
            }
            return ["ok": false, "error": "no combined power line"]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

    case "exec":
        guard let path = request["path"] as? String,
              allowedExecutables.contains(path),
              let arguments = request["args"] as? [String],
              arguments.count <= 8,
              arguments.allSatisfy({ $0.utf8.count <= 64 }),
              isSafeExec(path, arguments) else {
            return ["ok": false, "error": "not allowed"]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ["ok": true, "status": Int(process.terminationStatus),
                    "output": String(data: data, encoding: .utf8) ?? ""]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

    default:
        return ["ok": false, "error": "unknown command"]
    }
}

func serve(connection fd: Int32) {
    defer { close(fd) }
    // Validate the peer is the user that installed the helper.
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return }
    if ownerUID != 0, uid != 0, uid != ownerUID {
        return
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return }
        buffer.append(contentsOf: chunk[0..<count])
        guard buffer.count <= maxRequestBytes + 1 else { return }
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.count <= maxRequestBytes, !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let response = handle(object)
            guard let data = try? JSONSerialization.data(withJSONObject: response),
                  data.count <= maxResponseBytes else {
                var error = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "response too large"])) ?? Data()
                error.append(0x0A)
                _ = error.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                return
            }
            var payload = data
            payload.append(0x0A)
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }
}

// MARK: - Socket setup

unlink(socketPath)
let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else { fail("socket() failed") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    for (index, byte) in pathBytes.prefix(raw.count - 1).enumerated() { raw[index] = byte }
}
let addrLength = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, addrLength) }
}
guard bindResult == 0 else { fail("bind() failed") }
guard listen(serverFD, 16) == 0 else { fail("listen() failed") }

chmod(socketPath, 0o600)
if ownerUID != 0 {
    chown(socketPath, ownerUID, getgid())
}

signal(SIGPIPE, SIG_IGN)
// One connection per queue: `exec` runs powermetrics for up to a second, and a
// daemon that serves connections in series makes every fan write and SMC read
// behind it wait that long. SMC.shared serialises the IOKit calls itself.
let clients = DispatchQueue(label: "com.infinitycomputer.infinical.helper.clients",
                            qos: .userInitiated,
                            attributes: .concurrent)
while true {
    let client = accept(serverFD, nil, nil)
    if client < 0 { continue }
    clients.async { serve(connection: client) }
}
