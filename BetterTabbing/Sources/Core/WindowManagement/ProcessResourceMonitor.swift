import Foundation
import Darwin
import AppKit
import IOKit

/// Process resource monitor that computes real CPU usage percentages via
/// delta-based sampling (like Activity Monitor) and reads system temperature.
final class ProcessResourceMonitor: @unchecked Sendable {
    static let shared = ProcessResourceMonitor()

    // MARK: - Previous CPU sample for delta calculation

    private struct CPUSample {
        let timestamp: CFAbsoluteTime
        let userTime: UInt64   // nanoseconds
        let systemTime: UInt64 // nanoseconds
    }

    /// Previous per-process CPU samples keyed by PID
    private var previousSamples: [pid_t: CPUSample] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Public Types

    /// Snapshot of resource usage for a single process
    struct ResourceUsage {
        let memoryBytes: UInt64
        /// Instantaneous CPU usage percentage (0-100+ for multi-core)
        let cpuPercent: Double
    }

    /// A single entry in the system-wide resource monitor list
    struct ProcessResourceEntry: Identifiable {
        let id: pid_t
        let name: String
        let memoryBytes: UInt64
        /// CPU usage percentage since last sample (like Activity Monitor)
        let cpuPercent: Double

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
            if cpuPercent >= 100 {
                return String(format: "%.0f%%", cpuPercent)
            } else if cpuPercent >= 10 {
                return String(format: "%.1f%%", cpuPercent)
            } else if cpuPercent >= 0.1 {
                return String(format: "%.1f%%", cpuPercent)
            } else {
                return "0%"
            }
        }
    }

    /// System-wide memory summary
    struct SystemMemory {
        let totalBytes: UInt64
        let usedBytes: UInt64

        var freeBytes: UInt64 { totalBytes - min(usedBytes, totalBytes) }
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
        var usedPercent: Int { Int(round(usedFraction * 100)) }

        var formattedTotal: String { formatBytes(totalBytes) }
        var formattedUsed: String { formatBytes(usedBytes) }
        var formattedFree: String { formatBytes(freeBytes) }

        private func formatBytes(_ bytes: UInt64) -> String {
            let gb = Double(bytes) / (1024 * 1024 * 1024)
            if gb >= 1 {
                return String(format: "%.1f GB", gb)
            }
            return "\(Int(Double(bytes) / (1024 * 1024))) MB"
        }
    }

    /// System-wide CPU usage
    struct SystemCPU {
        let usagePercent: Double  // 0–100
        let coreCount: Int
    }

    // MARK: - System Memory

    func systemMemory() -> SystemMemory {
        let totalBytes = UInt64(ProcessInfo.processInfo.physicalMemory)

        let host = mach_host_self()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return SystemMemory(totalBytes: totalBytes, usedBytes: 0)
        }

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)

        // Match Activity Monitor: Used = App Memory + Wired + Compressed
        //
        // App Memory ≈ (active - purgeable) pages — internal app allocations
        // Wired     = wire_count pages — kernel/driver non-pageable memory
        // Compressed = compressor_page_count — pages squeezed by the compressor
        //
        // EXCLUDED: inactive pages (cached, reclaimable on demand — NOT "used")
        //           speculative pages (prefetched, also reclaimable)
        //           purgeable pages (can be discarded without paging)
        let appPages = UInt64(stats.internal_page_count)
            - UInt64(stats.purgeable_count)
        let usedPages = appPages
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)

        return SystemMemory(totalBytes: totalBytes, usedBytes: min(usedBytes, totalBytes))
    }

    // MARK: - System CPU

    private var previousHostCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func systemCPU() -> SystemCPU {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let host = mach_host_self()

        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return SystemCPU(usagePercent: 0, coreCount: coreCount)
        }

        let user = UInt64(loadInfo.cpu_ticks.0)
        let system = UInt64(loadInfo.cpu_ticks.1)
        let idle = UInt64(loadInfo.cpu_ticks.2)
        let nice = UInt64(loadInfo.cpu_ticks.3)

        defer {
            previousHostCPU = (user: user, system: system, idle: idle, nice: nice)
        }

        guard let prev = previousHostCPU else {
            return SystemCPU(usagePercent: 0, coreCount: coreCount)
        }

        let dUser = user - prev.user
        let dSystem = system - prev.system
        let dIdle = idle - prev.idle
        let dNice = nice - prev.nice
        let totalTicks = dUser + dSystem + dIdle + dNice

        guard totalTicks > 0 else {
            return SystemCPU(usagePercent: 0, coreCount: coreCount)
        }

        let usagePercent = Double(dUser + dSystem + dNice) / Double(totalTicks) * 100.0
        return SystemCPU(usagePercent: usagePercent, coreCount: coreCount)
    }

    // MARK: - CPU Temperature

    /// Thermal state from ProcessInfo (always available, no permissions needed)
    struct ThermalInfo {
        /// Exact temperature in °C, or nil if unavailable
        let temperature: Double?
        /// System thermal state (always available)
        let state: ProcessInfo.ThermalState
    }

    func thermalInfo() -> ThermalInfo {
        let state = ProcessInfo.processInfo.thermalState
        // Try SMC for real numeric temperature (works on Intel + Apple Silicon)
        if let temp = readSMCTemperature(), temp > 0 && temp < 130 {
            return ThermalInfo(temperature: temp, state: state)
        }
        // Fallback: IOHIDEvent temperature sensors (Apple Silicon)
        if let temp = readHIDTemperature(), temp > 0 && temp < 130 {
            return ThermalInfo(temperature: temp, state: state)
        }
        // Last resort: just thermal state (always available but no numeric value)
        return ThermalInfo(temperature: nil, state: state)
    }

    /// Read CPU temperature via SMC.
    /// Tries both Intel ("AppleSMC") and Apple Silicon ("AppleSMCKeysEndpoint") services,
    /// with architecture-specific sensor keys for each.
    private func readSMCTemperature() -> Double? {
        // Try both service names — Intel uses "AppleSMC", Apple Silicon uses "AppleSMCKeysEndpoint"
        let serviceNames = ["AppleSMC", "AppleSMCKeysEndpoint"]

        for serviceName in serviceNames {
            guard let matchDict = IOServiceMatching(serviceName) else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
            guard result == kIOReturnSuccess else { continue }
            defer { IOObjectRelease(iterator) }

            // Iterate ALL matching services (Apple Silicon may have multiple endpoints)
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var conn: io_connect_t = 0
                let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
                IOObjectRelease(service)

                if openResult == kIOReturnSuccess {
                    // Comprehensive key list for both architectures:
                    //   Intel: TC0P (proximity), TC0D (die), TC0E, TC0F
                    //   Apple Silicon P-cores: Tp09, Tp05, Tp0D, Tp0H, Tp0X, Tp0b
                    //   Apple Silicon E-cores: Tp01, Tp0L, Tp0P
                    //   Apple Silicon cluster/package: Tc0a, Tc0c, Tc0E, Tc0P, Tc1c
                    let keys = [
                        // Intel CPU
                        "TC0P", "TC0D", "TC0E", "TC0F",
                        // Apple Silicon CPU cluster averages (most representative)
                        "Tc0c", "Tc1c", "Tc0a", "Tc0E", "Tc0P",
                        // Apple Silicon individual P-cores
                        "Tp09", "Tp05", "Tp0D", "Tp0H", "Tp0X", "Tp0b",
                        // Apple Silicon individual E-cores
                        "Tp01", "Tp0L", "Tp0P",
                    ]

                    // Collect all valid readings to average (better than a single hotspot)
                    var readings: [Double] = []
                    for keyStr in keys {
                        if let value = readSMCKey(conn: conn, key: smcKeyCode(keyStr)),
                           value > 0 && value < 130 {
                            readings.append(value)
                            // If we already have a few, that's enough to be accurate
                            if readings.count >= 3 { break }
                        }
                    }

                    IOServiceClose(conn)

                    if !readings.isEmpty {
                        // Return the max reading (hottest core / cluster)
                        return readings.max()
                    }
                }

                service = IOIteratorNext(iterator)
            }
        }
        return nil
    }

    /// Read CPU temperature via IOHIDEventSystem (Apple Silicon fallback).
    /// Dynamically loads private IOHIDEvent APIs to read thermal sensors.
    private func readHIDTemperature() -> Double? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }

        // Function signatures for the private IOHIDEvent API
        typealias CreateFn       = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias SetMatchingFn  = @convention(c) (UnsafeMutableRawPointer, CFDictionary?) -> Void
        typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
        typealias CopyEventFn    = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int32) -> Unmanaged<CFTypeRef>?
        typealias GetFloatFn     = @convention(c) (CFTypeRef, UInt32) -> Double
        typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?

        guard let pCreate       = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let pSetMatching  = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let pCopyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let pCopyEvent    = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let pGetFloat     = dlsym(handle, "IOHIDEventGetFloatValue"),
              let pCopyProp     = dlsym(handle, "IOHIDServiceClientCopyProperty")
        else { return nil }

        let fnCreate       = unsafeBitCast(pCreate,       to: CreateFn.self)
        let fnSetMatching  = unsafeBitCast(pSetMatching,  to: SetMatchingFn.self)
        let fnCopyServices = unsafeBitCast(pCopyServices, to: CopyServicesFn.self)
        let fnCopyEvent    = unsafeBitCast(pCopyEvent,    to: CopyEventFn.self)
        let fnGetFloat     = unsafeBitCast(pGetFloat,     to: GetFloatFn.self)
        let fnCopyProp     = unsafeBitCast(pCopyProp,     to: CopyPropertyFn.self)

        guard let system = fnCreate(kCFAllocatorDefault) else { return nil }

        // Match temperature sensors: AppleVendor page (0xFF00), temperature usage (0x0005)
        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 0x0005
        ]
        fnSetMatching(system, matching as CFDictionary)

        guard let servicesRef = fnCopyServices(system)?.takeRetainedValue() as? [AnyObject],
              !servicesRef.isEmpty else { return nil }

        let kTemperatureEvent: Int64 = 15
        let kTemperatureField: UInt32 = UInt32(15) << 16 // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

        var cpuTemps: [Double] = []
        var allTemps: [Double] = []

        for service in servicesRef {
            let svc = Unmanaged.passUnretained(service).toOpaque()
            guard let eventRef = fnCopyEvent(svc, kTemperatureEvent, 0, 0) else { continue }
            let event = eventRef.takeRetainedValue()
            let temp = fnGetFloat(event as CFTypeRef, kTemperatureField)
            guard temp > 0 && temp < 130 else { continue }

            allTemps.append(temp)

            // Check sensor name to prioritize CPU-related sensors
            if let nameRef = fnCopyProp(svc, "Product" as CFString) {
                let name = (nameRef.takeRetainedValue() as? String ?? "").lowercased()
                if name.contains("cpu") || name.contains("die") || name.contains("pmgr")
                    || name.contains("soc") || name.contains("cluster") {
                    cpuTemps.append(temp)
                }
            }
        }

        // Prefer CPU-specific sensors; fall back to overall max
        if !cpuTemps.isEmpty {
            return cpuTemps.max()
        }
        return allTemps.isEmpty ? nil : allTemps.max()
    }

    private func smcKeyCode(_ str: String) -> UInt32 {
        let chars = Array(str.utf8)
        guard chars.count == 4 else { return 0 }
        return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
    }

    // SMC kernel structs — use nested structs so Swift computes alignment
    // padding automatically, matching the C kernel layout exactly.
    // The flattened approach was WRONG: it lost padding between nested struct
    // boundaries (e.g. after keyInfo_dataAttributes), shifting data8/bytes offsets.

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // Explicit padding to match C sizeof (alignment 4 → 12 bytes total).
        // Without this, Swift sizes the struct at 9 bytes, shifting every
        // subsequent field in SMCKeyData by 3 bytes and breaking IOKit calls.
        private var _pad0: UInt8 = 0
        private var _pad1: UInt8 = 0
        private var _pad2: UInt8 = 0
    }

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private func readSMCKey(conn: io_connect_t, key: UInt32) -> Double? {
        var inputStruct = SMCKeyData()
        var outputStruct = SMCKeyData()

        // Step 1: get key info
        inputStruct.key = key
        inputStruct.data8 = 9 // kSMCGetKeyInfo

        var outputSize = MemoryLayout<SMCKeyData>.size
        let infoResult = withUnsafeMutablePointer(to: &inputStruct) { inPtr in
            withUnsafeMutablePointer(to: &outputStruct) { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr, MemoryLayout<SMCKeyData>.size, outPtr, &outputSize)
            }
        }
        guard infoResult == kIOReturnSuccess else { return nil }

        // Step 2: read key value
        inputStruct.keyInfo.dataSize = outputStruct.keyInfo.dataSize
        inputStruct.data8 = 5 // kSMCReadKey
        outputSize = MemoryLayout<SMCKeyData>.size

        let readResult = withUnsafeMutablePointer(to: &inputStruct) { inPtr in
            withUnsafeMutablePointer(to: &outputStruct) { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr, MemoryLayout<SMCKeyData>.size, outPtr, &outputSize)
            }
        }
        guard readResult == kIOReturnSuccess else { return nil }

        let dataType = outputStruct.keyInfo.dataType
        let byte0 = outputStruct.bytes.0
        let byte1 = outputStruct.bytes.1

        // fpe2: unsigned fixed-point 14.2
        if dataType == smcKeyCode("fpe2") {
            let raw = (UInt16(byte0) << 8) | UInt16(byte1)
            return Double(raw) / 4.0
        }
        // sp78: signed fixed-point 7.8
        if dataType == smcKeyCode("sp78") {
            let raw = Int16(bitPattern: (UInt16(byte0) << 8) | UInt16(byte1))
            return Double(raw) / 256.0
        }
        // flt: IEEE float32
        if dataType == smcKeyCode("flt ") && outputStruct.keyInfo.dataSize >= 4 {
            let b = outputStruct.bytes
            var float: Float = 0
            withUnsafeMutablePointer(to: &float) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { dest in
                    dest[0] = b.0; dest[1] = b.1; dest[2] = b.2; dest[3] = b.3
                }
            }
            return Double(float)
        }

        return nil // Unknown type, don't guess
    }

    // MARK: - Per-Process Snapshot (with CPU %)

    func snapshot(pids: [pid_t]) -> [pid_t: ResourceUsage] {
        let now = CFAbsoluteTimeGetCurrent()
        var result: [pid_t: ResourceUsage] = [:]
        result.reserveCapacity(pids.count)

        lock.lock()
        for pid in pids {
            if let usage = resourceUsage(for: pid, now: now) {
                result[pid] = usage
            }
        }
        lock.unlock()

        return result
    }

    /// System-wide snapshot sorted by memory descending (like Activity Monitor).
    /// Returns up to `limit` entries. Set higher to see more processes.
    func systemSnapshot(limit: Int = 200) -> [ProcessResourceEntry] {
        let now = CFAbsoluteTimeGetCurrent()
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(bufferSize))
        let actualSize = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard actualSize > 0 else { return [] }
        let pidCount = Int(actualSize)

        // NSWorkspace only knows about GUI apps — daemon/helper names come from proc_name/proc_pidpath
        var appNameByPid: [pid_t: String] = [:]
        var guiPids = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guiPids.insert(pid)
            if let name = app.localizedName {
                appNameByPid[pid] = name
            }
        }

        var entries: [ProcessResourceEntry] = []
        entries.reserveCapacity(min(pidCount, limit * 2))
        var seenPids = Set<pid_t>()

        lock.lock()
        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            // Try full resource usage first
            let memoryBytes: UInt64
            let cpuPercent: Double

            if let usage = resourceUsage(for: pid, now: now) {
                memoryBytes = usage.memoryBytes
                cpuPercent = usage.cpuPercent
            } else {
                // Fallback: try proc_pidinfo alone for processes where
                // proc_pid_rusage fails (permission denied for some daemons).
                var taskInfo = proc_taskinfo()
                let taskInfoSize = MemoryLayout<proc_taskinfo>.stride
                let bytesRead = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))
                if bytesRead == taskInfoSize {
                    memoryBytes = UInt64(taskInfo.pti_resident_size)
                    let currentUser = taskInfo.pti_total_user
                    let currentSystem = taskInfo.pti_total_system
                    let sample = CPUSample(timestamp: now, userTime: currentUser, systemTime: currentSystem)
                    if let prev = previousSamples[pid], now - prev.timestamp > 0.05 {
                        let dt = now - prev.timestamp
                        let dUser = currentUser > prev.userTime ? currentUser - prev.userTime : 0
                        let dSystem = currentSystem > prev.systemTime ? currentSystem - prev.systemTime : 0
                        cpuPercent = Double(dUser + dSystem) / (dt * 1_000_000_000.0) * 100.0
                    } else {
                        cpuPercent = 0
                    }
                    previousSamples[pid] = sample
                } else {
                    // If this is a known GUI app, still include it with 0 values
                    // rather than skipping — the user expects to see it
                    if guiPids.contains(pid), let appName = appNameByPid[pid] {
                        entries.append(ProcessResourceEntry(
                            id: pid,
                            name: appName,
                            memoryBytes: 0,
                            cpuPercent: 0
                        ))
                        seenPids.insert(pid)
                    }
                    continue
                }
            }

            // Only filter out truly negligible processes: < 100 KB AND 0% CPU
            // BUT never filter out known GUI apps — user expects to see them
            if memoryBytes < 102_400 && cpuPercent < 0.1 && !guiPids.contains(pid) {
                continue
            }

            let name: String
            if let appName = appNameByPid[pid] {
                name = appName
            } else {
                // Try proc_pidpath first for full binary name (better than proc_name
                // which truncates at MAXCOMLEN = 16 chars)
                var pathBuffer = [CChar](repeating: 0, count: 4096)
                let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
                if pathLen > 0 {
                    let fullPath: String
                    if let nullIdx = pathBuffer.firstIndex(of: 0) {
                        fullPath = String(decoding: pathBuffer[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    } else {
                        fullPath = String(decoding: pathBuffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                    // Extract the binary name from the path
                    let binaryName = (fullPath as NSString).lastPathComponent
                    if !binaryName.isEmpty {
                        name = binaryName
                    } else {
                        name = resolveProcessName(pid: pid)
                    }
                } else {
                    name = resolveProcessName(pid: pid)
                }
                if name.isEmpty { continue }
            }

            seenPids.insert(pid)
            entries.append(ProcessResourceEntry(
                id: pid,
                name: name,
                memoryBytes: memoryBytes,
                cpuPercent: cpuPercent
            ))
        }
        lock.unlock()

        // Sort by memory descending (heaviest first), CPU% as tiebreaker
        entries.sort {
            if $0.memoryBytes != $1.memoryBytes {
                return $0.memoryBytes > $1.memoryBytes
            }
            return $0.cpuPercent > $1.cpuPercent
        }
        return Array(entries.prefix(limit))
    }

    /// Resolve a process name via proc_name (fallback when proc_pidpath unavailable)
    private func resolveProcessName(pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if let nullIdx = nameBuffer.firstIndex(of: 0) {
            return String(decoding: nameBuffer[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            return String(decoding: nameBuffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Clear stored CPU samples (call when monitor is deactivated)
    func resetSamples() {
        lock.lock()
        previousSamples.removeAll()
        previousHostCPU = nil
        lock.unlock()
    }

    // MARK: - Private

    /// Get resource usage with delta-based CPU percentage
    private func resourceUsage(for pid: pid_t, now: CFAbsoluteTime) -> ResourceUsage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rustPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rustPtr)
            }
        }
        guard result == 0 else { return nil }

        let memoryBytes = info.ri_phys_footprint

        // Read current CPU time
        var taskInfo = proc_taskinfo()
        let taskInfoSize = MemoryLayout<proc_taskinfo>.stride
        let bytesRead = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(taskInfoSize))

        let cpuPercent: Double
        if bytesRead == taskInfoSize {
            let currentUser = taskInfo.pti_total_user
            let currentSystem = taskInfo.pti_total_system
            let currentSample = CPUSample(timestamp: now, userTime: currentUser, systemTime: currentSystem)

            if let prev = previousSamples[pid] {
                let dt = now - prev.timestamp
                if dt > 0.05 { // Need at least 50ms between samples
                    let dUser = currentUser > prev.userTime ? currentUser - prev.userTime : 0
                    let dSystem = currentSystem > prev.systemTime ? currentSystem - prev.systemTime : 0
                    let totalCPUns = Double(dUser + dSystem)
                    let wallNs = dt * 1_000_000_000.0
                    // Percentage of one core; can exceed 100 for multi-threaded
                    cpuPercent = (totalCPUns / wallNs) * 100.0
                } else {
                    // Too soon for a meaningful delta, reuse last known
                    cpuPercent = 0
                }
            } else {
                cpuPercent = 0 // First sample, no delta yet
            }

            previousSamples[pid] = currentSample
        } else {
            cpuPercent = 0
        }

        return ResourceUsage(memoryBytes: memoryBytes, cpuPercent: cpuPercent)
    }
}
