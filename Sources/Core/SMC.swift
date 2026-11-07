//
//  SMC.swift
//  Low level AppleSMC access (IOKit user client).
//
//  The 80 byte payload layout below is the layout the AppleSMC driver expects.
//  Offsets are written explicitly with unaligned stores so the Swift struct
//  cannot accidentally introduce different padding than the kernel side.
//

import Foundation
import Darwin
import IOKit

struct SMCKeyInfo {
    var size: UInt32 = 0
    var type: String = ""
    var attributes: UInt8 = 0
    /// SMC marks a key writable when bit 0x40 of the attribute byte is set.
    var isWritable: Bool { attributes & 0x40 != 0 }

    /// 1 字节控制键的类型名。`ui8 ` 是标准无符号字节，`hex_` 是原始字节，
    /// `ch8*` / `flag` 是同一宽度的变体。
    ///
    /// This has to match `WriteValidation.isOneByteControlType` in
    /// `Helper/main.swift`: the helper runs as root and validates every write
    /// itself, so a key the app considers writable but the helper refuses turns
    /// into a confusing "write rejected" at the worst moment. The two live in
    /// different targets and cannot share code, which is why the rule is
    /// written down in both places.
    var isOneByteControl: Bool {
        size == 1 && (type == "ui8 " || type == "hex_" || type == "ch8*" || type == "flag")
    }

    /// 4 字节控制键（CHTE）的类型名，理由同上。
    var isFourByteControl: Bool {
        size == 4 && (type == "ui32" || type == "u32 " || type == "hex_" || type == "ch8*")
    }
}

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case keyNotFound(String)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case unsupportedType(String)
    case invalidWriteSize(String, Int, UInt32)

    var description: String {
        switch self {
        case .serviceNotFound: return t("未找到 AppleSMC 服务")
        case .openFailed(let kr): return String(format: t("无法连接 AppleSMC (0x%x)"), kr)
        case .keyNotFound(let k): return tf("SMC 键 {p} 不存在", k)
        case .readFailed(let k, let r): return tf("读取 {p} 失败 (0x{p})", k, String(r, radix: 16))
        case .writeFailed(let k, let r): return tf("写入 {p} 失败 (0x{p})", k, String(r, radix: 16))
        case .unsupportedType(let t): return tf("不支持的数据类型 {p}", t)
        case .invalidWriteSize(let key, let actual, let expected):
            return "SMC \(key): invalid write size \(actual), expected \(expected) (1...32 bytes)"
        }
    }
}

final class SMC {

    static let shared = SMC()

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let payloadSize = 80

    private init() {}

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    @discardableResult
    func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { return false }
        connection = conn
        return true
    }

    // MARK: - Raw call

    private func call(_ payload: inout [UInt8]) -> (kern_return_t, [UInt8]) {
        var output = [UInt8](repeating: 0, count: SMC.payloadSize)
        var outputSize = SMC.payloadSize
        let kr = payload.withUnsafeBytes { inputPtr -> kern_return_t in
            output.withUnsafeMutableBytes { outPtr -> kern_return_t in
                IOConnectCallStructMethod(connection,
                                          SMC.kernelIndex,
                                          inputPtr.baseAddress!,
                                          SMC.payloadSize,
                                          outPtr.baseAddress!,
                                          &outputSize)
            }
        }
        return (kr, output)
    }

    private static func keyCode(_ key: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in key.utf8.prefix(4) { code = (code << 8) | UInt32(byte) }
        return code
    }

    private static func typeString(_ raw: UInt32) -> String {
        let bytes: [UInt8] = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                              UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Key info

    func keyInfo(_ key: String) -> SMCKeyInfo? {
        guard open() else { return nil }
        lock.lock(); defer { lock.unlock() }
        var payload = [UInt8](repeating: 0, count: SMC.payloadSize)
        payload.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: SMC.keyCode(key), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: SMC.cmdReadKeyInfo, toByteOffset: 42, as: UInt8.self)
        }
        let (kr, output) = call(&payload)
        guard kr == KERN_SUCCESS else { return nil }
        let result = Int8(bitPattern: output[40])
        guard result == 0 else { return nil }
        let info = output.withUnsafeBytes { raw -> SMCKeyInfo in
            let size = SMC.loadU32(raw, 28)
            let type = SMC.loadU32(raw, 32)
            let attrs = SMC.loadU8(raw, 36)
            return SMCKeyInfo(size: size, type: SMC.typeString(type), attributes: attrs)
        }
        return info
    }

    func exists(_ key: String) -> Bool { keyInfo(key) != nil }

    // MARK: - Enumeration

    private static let cmdReadIndex: UInt8 = 8

    /// Number of keys the SMC exposes, from `#KEY`.
    func keyCount() -> Int? {
        guard open() else { return nil }
        guard let (_, bytes) = try? readBytes("#KEY"), bytes.count == 4 else { return nil }
        return Int(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    /// Key name at a given index (`SMC_CMD_READ_INDEX`).
    func key(at index: Int) -> String? {
        guard open() else { return nil }
        lock.lock(); defer { lock.unlock() }
        var payload = [UInt8](repeating: 0, count: SMC.payloadSize)
        payload.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: SMC.cmdReadIndex, toByteOffset: 42, as: UInt8.self)
            raw.storeBytes(of: UInt32(index), toByteOffset: 44, as: UInt32.self)
        }
        let (kr, output) = call(&payload)
        guard kr == KERN_SUCCESS, Int8(bitPattern: output[40]) == 0 else { return nil }
        let code = output.withUnsafeBytes { SMC.loadU32($0, 0) }
        let name = SMC.typeString(code)
        // Print ASCII only, including keys like "AC-W" and "FS! " that carry
        // punctuation or a trailing space.
        guard name.allSatisfy({ $0.isASCII && ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) < 127 }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    /// Every key name the SMC exposes. Used by the helper's `keys` command
    /// (diagnostics), not by the app itself — `Sources/` never calls it, so a
    /// scan that only looks at the app target will read this as dead code.
    func allKeys(limit: Int = 8192) -> [String] {
        guard let count = keyCount(), count > 0, count < limit else { return [] }
        return (0..<count).compactMap { key(at: $0) }
    }

    // MARK: - Read

    /// Returns the raw bytes of an SMC key.
    func readBytes(_ key: String) throws -> (SMCKeyInfo, [UInt8]) {
        guard open() else { throw SMCError.serviceNotFound }
        guard let info = keyInfo(key) else { throw SMCError.keyNotFound(key) }
        lock.lock(); defer { lock.unlock() }
        var payload = [UInt8](repeating: 0, count: SMC.payloadSize)
        payload.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: SMC.keyCode(key), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: info.size, toByteOffset: 28, as: UInt32.self)
            raw.storeBytes(of: SMC.typeCode(info.type), toByteOffset: 32, as: UInt32.self)
            raw.storeBytes(of: info.attributes, toByteOffset: 36, as: UInt8.self)
            raw.storeBytes(of: SMC.cmdReadBytes, toByteOffset: 42, as: UInt8.self)
        }
        let (kr, output) = call(&payload)
        guard kr == KERN_SUCCESS else { throw SMCError.readFailed(key, Int32(truncatingIfNeeded: kr)) }
        let result = Int8(bitPattern: output[40])
        guard result == 0 else { throw SMCError.readFailed(key, Int32(result)) }
        let count = Int(min(info.size, 32))
        return (info, Array(output[48..<(48 + count)]))
    }

    // MARK: - Write

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        guard open() else { throw SMCError.serviceNotFound }
        guard let info = keyInfo(key) else { throw SMCError.keyNotFound(key) }
        // Do not silently zero-pad a short value or truncate a long one: either
        // can change unrelated bits in a multi-byte hardware control register.
        guard info.size > 0, info.size <= 32, bytes.count == Int(info.size) else {
            throw SMCError.invalidWriteSize(key, bytes.count, info.size)
        }
        var payload = [UInt8](repeating: 0, count: SMC.payloadSize)
        payload.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: SMC.keyCode(key), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: info.size, toByteOffset: 28, as: UInt32.self)
            raw.storeBytes(of: SMC.typeCode(info.type), toByteOffset: 32, as: UInt32.self)
            raw.storeBytes(of: info.attributes, toByteOffset: 36, as: UInt8.self)
            raw.storeBytes(of: SMC.cmdWriteBytes, toByteOffset: 42, as: UInt8.self)
            for (index, byte) in bytes.prefix(32).enumerated() {
                raw.storeBytes(of: byte, toByteOffset: 48 + index, as: UInt8.self)
            }
        }
        lock.lock()
        let (kr, output) = call(&payload)
        lock.unlock()
        guard kr == KERN_SUCCESS else { throw SMCError.writeFailed(key, Int32(truncatingIfNeeded: kr)) }
        let result = Int8(bitPattern: output[40])
        guard result == 0 else { throw SMCError.writeFailed(key, Int32(result)) }
    }

    private static func typeCode(_ type: String) -> UInt32 {
        var code: UInt32 = 0
        let bytes = Array(type.utf8)
        for i in 0..<4 { code = (code << 8) | UInt32(i < bytes.count ? bytes[i] : 0x20) }
        return code
    }

    // MARK: - Alignment safe loads (macOS 12 compatible, no loadUnaligned)

    fileprivate static func loadU8(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt8 {
        raw[offset]
    }

    fileprivate static func loadU32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 4)]))
        }
        return value
    }

    fileprivate static func loadU16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        var value: UInt16 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 2)]))
        }
        return value
    }

    fileprivate static func loadI16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Int16 {
        Int16(bitPattern: loadU16(raw, offset))
    }

    fileprivate static func loadF32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Float32 {
        Float32(bitPattern: loadU32(raw, offset))
    }

    // MARK: - Typed helpers

    func readDouble(_ key: String) throws -> Double {
        let (info, bytes) = try readBytes(key)
        return try SMC.decode(info: info, bytes: bytes)
    }

    static func decode(info: SMCKeyInfo, bytes: [UInt8]) throws -> Double {
        let needed: Int
        switch info.type {
        case "flt ", "ui32", "si32": needed = 4
        case "ui16", "si16", "sp78", "fp88", "fpe2": needed = 2
        default: needed = 1
        }
        guard bytes.count >= needed else { throw SMCError.unsupportedType(info.type) }
        return try bytes.withUnsafeBytes { raw -> Double in
            switch info.type {
            case "flt ": return Double(loadF32(raw, 0))
            case "ui8 ": return Double(loadU8(raw, 0))
            case "si8 ": return Double(Int8(bitPattern: loadU8(raw, 0)))
            case "ui16": return Double(loadU16(raw, 0))
            case "si16": return Double(loadI16(raw, 0))
            case "ui32": return Double(loadU32(raw, 0))
            case "si32": return Double(Int32(bitPattern: loadU32(raw, 0)))
            case "sp78": return Double(loadI16(raw, 0)) / 256.0
            case "fp88": return Double(Int8(bitPattern: loadU8(raw, 0))) + Double(loadU8(raw, 1)) / 256.0
            case "fpe2": return Double(loadU16(raw, 0)) / 4.0
            default: throw SMCError.unsupportedType(info.type)
            }
        }
    }


    func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, [value])
    }
}
