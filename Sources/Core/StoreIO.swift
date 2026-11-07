//
//  StoreIO.swift
//  Crash-safe JSON stores: read with a rolling backup, never overwrite in anger.
//
//  Before this both stores decoded with `try?` and fell back to an empty array.
//  A single unreadable byte therefore turned into "no data", and the next save
//  wrote that emptiness over the only copy. Losing 400 days of history to a
//  truncated write is not a graceful degradation, it is data loss.
//
//  The rules here are:
//    • a file that does not decode is *moved aside* before anything else runs,
//      so the bytes survive for inspection;
//    • a readable backup is preferred over an empty store;
//    • the caller decides whether rotation is allowed, because rotating a file
//      that was never read would push a corrupt copy over a good backup.
//

import Foundation

/// What happened when a store file was read.
enum StoreReadStatus: Equatable {
    /// Decoded on the first try, or the file did not exist yet.
    case clean
    /// The file could not be decoded; the previous backup was used instead.
    case recoveredFromBackup(quarantine: String?)
    /// Neither the file nor its backup could be decoded. The store starts
    /// empty; whatever was there is preserved at `quarantine`.
    case startedEmpty(quarantine: String?)

    var needsAttention: Bool {
        if case .clean = self { return false }
        return true
    }

    /// Where the unreadable file was kept, if it could be moved at all.
    var quarantinePath: String? {
        switch self {
        case .clean: return nil
        case .recoveredFromBackup(let path), .startedEmpty(let path): return path
        }
    }
}

struct StoreRead<Value> {
    var value: Value
    var status: StoreReadStatus
    /// True when a decodable copy is now at the main path, so the next save may
    /// copy it into the backup slot. False after `.startedEmpty`: there is
    /// nothing worth preserving and the old backup may itself be the corrupt
    /// one.
    var safeToRotate: Bool
}

enum StoreIO {

    // MARK: - Paths

    /// `daily.json` → `daily.bak.json`
    static func backupURL(for file: URL) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appendingPathComponent(base + ".bak.json")
    }

    /// `daily.json` → `daily.corrupt-20261107-102030.json`
    static func quarantineURL(for file: URL, now: Date = Date()) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        let name = base + ".corrupt-" + stamp(now) + ".json"
        return file.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Fixed-width, sortable, timezone-free: the file name is a record of when
    /// the damage was noticed, not of where the machine happened to be.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Home-relative for display: a support-file path contains the account name.
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func unique(_ base: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: base.path) else { return base }
        let directory = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        for index in 1...99 {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).json")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return base
    }

    // MARK: - Read

    static func load<Element: Codable>(_ type: Element.Type,
                                         from file: URL,
                                         now: Date = Date()) -> StoreRead<[Element]> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            // No main file. Either this is the first run, or something removed
            // it. A readable backup is the difference between the two, and it
            // costs nothing to look.
            let backup = backupURL(for: file)
            if let value = decode(type, at: backup) {
                _ = write(value, to: file)
                return StoreRead(value: value,
                                 status: .recoveredFromBackup(quarantine: nil),
                                 safeToRotate: true)
            }
            // First run: not a failure, and nothing to rotate.
            return StoreRead(value: [], status: .clean, safeToRotate: false)
        }
        if let value = decode(type, at: file) {
            return StoreRead(value: value, status: .clean, safeToRotate: true)
        }

        // Unreadable. Move it aside first: every later step may write.
        let quarantine = unique(quarantineURL(for: file, now: now))
        let moved = (try? manager.moveItem(at: file, to: quarantine)) != nil
        let kept = moved ? quarantine.path : nil

        let backup = backupURL(for: file)
        if let value = decode(type, at: backup) {
            // Put the recovered copy back at the main path, so the process keeps
            // running on real data and the next save is an ordinary overwrite.
            _ = write(value, to: file)
            return StoreRead(value: value,
                             status: .recoveredFromBackup(quarantine: kept),
                             safeToRotate: true)
        }
        return StoreRead(value: [], status: .startedEmpty(quarantine: kept), safeToRotate: false)
    }

    // MARK: - Write

    @discardableResult
    static func save<Element: Encodable>(_ value: [Element], to file: URL, rotate: Bool) -> Bool {
        guard let data = encoded(value) else { return false }
        if rotate, FileManager.default.fileExists(atPath: file.path) {
            let backup = backupURL(for: file)
            try? FileManager.default.removeItem(at: backup)
            // Copy, not move: if the write below fails the main file is still
            // the newest good copy.
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        return (try? data.write(to: file, options: [.atomic])) != nil
    }

    /// Removes the store and its backup. Used by "clear history", where keeping
    /// a backup would let a later recovery resurrect what the user deleted.
    static func discard(file: URL) {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: backupURL(for: file))
    }

    // MARK: - Encoding

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func decode<Element: Decodable>(_ type: Element.Type, at url: URL) -> [Element]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? decoder().decode([Element].self, from: data)
    }

    private static func encoded<Element: Encodable>(_ value: [Element]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    private static func write<Element: Encodable>(_ value: [Element], to url: URL) -> Bool {
        guard let data = encoded(value) else { return false }
        return (try? data.write(to: url, options: [.atomic])) != nil
    }
}