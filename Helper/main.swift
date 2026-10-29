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

let allowedExecutables: Set<String> = ["/usr/bin/pmset", "/usr/bin/killall", "/usr/bin/caffeinate", "/usr/bin/powermetrics"]

let smc = SMC.shared

func handle(_ request: [String: Any]) -> [String: Any] {
    let command = (request["cmd"] as? String) ?? ""
    switch command {
    case "ping":
        return ["ok": true, "version": 1, "pid": ProcessInfo.processInfo.processIdentifier]

    case "info":
        guard let keys = request["keys"] as? [String] else {
            return ["ok": false, "error": "bad keys"]
        }
        var rows: [[String: Any]] = []
        for key in keys where key.count == 4 {
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
        guard let key = request["key"] as? String, key.count == 4 else {
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
              let hex = request["bytes"] as? String else {
            return ["ok": false, "error": "bad request"]
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
        guard let path = request["path"] as? String, allowedExecutables.contains(path),
              let arguments = request["args"] as? [String] else {
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
    if getpeereid(fd, &uid, &gid) == 0, ownerUID != 0, uid != 0, uid != ownerUID {
        return
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let response = handle(object)
            guard let data = try? JSONSerialization.data(withJSONObject: response) else { continue }
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
