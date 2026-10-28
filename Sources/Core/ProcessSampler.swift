//
//  ProcessSampler.swift
//  Which processes were actually burning CPU while the pack was discharging.
//
//  libproc only: no shell spawn, no privileges, no helper. Other users'
//  processes fail `proc_pid_rusage` with EPERM and are simply skipped, which is
//  the right outcome — they are not ours to attribute.
//

import Foundation
import Darwin

struct ProcessLoad: Equatable {
    var name: String
    /// Percent of one core over the sampling interval. Can exceed 100 for a
    /// multi-threaded process, same convention as `ps` / Activity Monitor.
    var cpuPercent: Double
}

enum ProcessSampler {

    private struct Sample {
        var name: String
        /// user + system CPU time, nanoseconds.
        var cpuTime: UInt64
    }

    /// `proc_pid_rusage` reports CPU time in mach absolute ticks, not the
    /// nanoseconds its header implies. Verified against `getrusage(RUSAGE_SELF)`
    /// on macOS 26 / M2 Pro: 32,873,001 ticks == 1.370 s of CPU, i.e. the 24 MHz
    /// timebase (numer 125 / denom 3). Dividing by 1e9 instead would report
    /// every process at 2.4 % of its real share.
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return 1e-9 }
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    /// Two snapshots `interval` apart, diffed per pid. Synchronous and blocking
    /// for `interval` seconds — call it from a background queue.
    static func topProcesses(interval: TimeInterval,
                             limit: Int,
                             excluding: Set<pid_t> = []) -> [ProcessLoad] {
        let before = snapshot(excluding: excluding)
        guard !before.isEmpty else { return [] }
        Thread.sleep(forTimeInterval: interval)
        let after = snapshot(excluding: excluding)
        guard !after.isEmpty else { return [] }

        let seconds = max(0.1, interval)
        var loads: [ProcessLoad] = []
        for (pid, current) in after {
            guard let previous = before[pid], current.cpuTime > previous.cpuTime else { continue }
            let deltaSeconds = Double(current.cpuTime - previous.cpuTime) * secondsPerTick
            let percent = deltaSeconds / seconds * 100
            guard percent >= 1 else { continue }
            loads.append(ProcessLoad(name: current.name, cpuPercent: percent))
        }
        return Array(loads.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    private static func snapshot(excluding: Set<pid_t>) -> [pid_t: Sample] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        // Returns the number of pids written, not a byte count — measured on
        // macOS 26: a buffer of 851 pids reports 852.
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [:] }

        var result: [pid_t: Sample] = [:]
        for index in 0..<min(Int(count), capacity) {
            let pid = pids[index]
            guard pid > 0, !excluding.contains(pid) else { continue }

            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            guard ok == 0 else { continue }

            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let name = String(cString: path).split(separator: "/").last.map(String.init) ?? "?"

            result[pid] = Sample(name: name, cpuTime: usage.ri_user_time + usage.ri_system_time)
        }
        return result
    }
}
