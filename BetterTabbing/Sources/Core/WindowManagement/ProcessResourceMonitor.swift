import Foundation
import Darwin
import AppKit

/// Lightweight process resource monitor that uses proc_pid_rusage for memory
/// and proc_pidinfo for CPU stats. Designed to be called once per switcher
/// show — not continuously polled.
final class ProcessResourceMonitor: @unchecked Sendable {
    static let shared = ProcessResourceMonitor()

    private init() {}

    /// Snapshot of resource usage for a single process
    struct ResourceUsage {
        /// Resident memory in bytes
        let memoryBytes: UInt64
        /// Cumulative CPU time in seconds
        let cpuSeconds: Double
    }

    /// A single entry in the system-wide resource monitor list
    struct ProcessResourceEntry: Identifiable {
        let id: pid_t
        let name: String
        let memoryBytes: UInt64
        let cpuSeconds: Double

        var formattedMemory: String {
            let mb = Double(memoryBytes) / (1024 * 1024)
            if mb >= 1024 {
                return String(format: "%.1f GB", mb / 1024)
            } else if mb >= 1 {
                return "\(Int(mb)) MB"
            } else {
                return "<1 MB"
            }
        }

        var formattedCPU: String {
            if cpuSeconds >= 3600 {
                return String(format: "%.1fh", cpuSeconds / 3600)
            } else if cpuSeconds >= 60 {
                return String(format: "%.1fm", cpuSeconds / 60)
            } else {
                return String(format: "%.1fs", cpuSeconds)
            }
        }
    }

    // MARK: - Public API

    /// Fetch resource usage for a list of PIDs. Returns a dictionary keyed by PID.
    /// This is intentionally synchronous and fast (~1-3ms for ~20 apps).
    func snapshot(pids: [pid_t]) -> [pid_t: ResourceUsage] {
        var result: [pid_t: ResourceUsage] = [:]
        result.reserveCapacity(pids.count)

        for pid in pids {
            if let usage = resourceUsage(for: pid) {
                result[pid] = usage
            }
        }

        return result
    }

    /// Get a system-wide snapshot of top resource-consuming processes.
    /// Returns up to `limit` entries sorted by memory descending.
    /// Synchronous, typically ~5-15ms for a full system scan.
    func systemSnapshot(limit: Int = 15) -> [ProcessResourceEntry] {
        // Get all PIDs on the system
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bufferSize))
        let actualSize = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard actualSize > 0 else { return [] }

        let pidCount = Int(actualSize)

        // Build a lookup of running app names by PID for user-facing processes
        var appNameByPid: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName {
                appNameByPid[app.processIdentifier] = name
            }
        }

        var entries: [ProcessResourceEntry] = []
        entries.reserveCapacity(min(pidCount, limit * 2))

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            guard let usage = resourceUsage(for: pid) else { continue }

            // Skip tiny processes (< 1 MB) to reduce noise
            guard usage.memoryBytes > 1_048_576 else { continue }

            // Get process name: prefer app display name, fall back to proc_name
            let name: String
            if let appName = appNameByPid[pid] {
                name = appName
            } else {
                var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
                proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                let procName: String
                if let nullIdx = nameBuffer.firstIndex(of: 0) {
                    procName = String(decoding: nameBuffer[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                } else {
                    procName = String(decoding: nameBuffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                if procName.isEmpty { continue }
                name = procName
            }

            entries.append(ProcessResourceEntry(
                id: pid,
                name: name,
                memoryBytes: usage.memoryBytes,
                cpuSeconds: usage.cpuSeconds
            ))
        }

        // Sort by memory descending and take top N
        entries.sort { $0.memoryBytes > $1.memoryBytes }
        return Array(entries.prefix(limit))
    }

    // MARK: - Private

    /// Get resource usage for a single PID using proc_pid_rusage (lightweight kernel call)
    private func resourceUsage(for pid: pid_t) -> ResourceUsage? {
        // Use rusage_info_v2 for memory info
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rustPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rustPtr)
            }
        }

        guard result == 0 else { return nil }

        let memoryBytes = info.ri_phys_footprint

        // Read proc task info for CPU time
        var taskInfo = proc_taskinfo()
        let taskInfoSize = MemoryLayout<proc_taskinfo>.stride
        let bytesRead = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))

        let cpuSeconds: Double
        if bytesRead == taskInfoSize {
            let totalCPUTimeNs = taskInfo.pti_total_user + taskInfo.pti_total_system
            cpuSeconds = Double(totalCPUTimeNs) / 1_000_000_000.0
        } else {
            cpuSeconds = 0
        }

        return ResourceUsage(memoryBytes: memoryBytes, cpuSeconds: cpuSeconds)
    }
}
