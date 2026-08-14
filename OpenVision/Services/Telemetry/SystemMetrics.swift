// OpenVision - SystemMetrics.swift
// Point-in-time device readings: memory, CPU, thermal, battery.
//
// WHAT iOS WILL NOT GIVE US (so nobody re-searches for it):
//   • Temperature in degrees — there is no public thermal-sensor API. `ProcessInfo.thermalState`
//     is the sanctioned proxy and has four buckets. Android dashboards showing "skin 25.3°C /
//     soc 32.6°C" read sysfs, which has no iOS equivalent.
//   • Per-core CPU frequency / per-cluster load — no public API. We report OUR process's CPU,
//     summed across its threads, not the system's.
//   • GPU utilisation — no public API. MLX inference load has to be inferred from tok/s.
//
// Everything here is cheap enough to sample at ~1 Hz and is safe off the main thread.

import Foundation
import UIKit

/// One sample of device state.
struct SystemMetrics: Sendable {
    /// Our process's physical footprint — the number jetsam actually judges us on.
    let memoryFootprintBytes: UInt64
    /// Headroom before this process is killed. Matches `os_proc_available_memory()`.
    let memoryAvailableBytes: UInt64
    /// Total device RAM, for context in the UI.
    let memoryTotalBytes: UInt64
    /// Summed CPU usage across our threads, 0–100 per core (so >100 is possible and normal).
    let cpuPercent: Double
    let thermalState: ProcessInfo.ThermalState
    /// 0.0–1.0, or nil when battery monitoring is off/unavailable (e.g. Simulator).
    let batteryLevel: Float?
    let isLowPowerMode: Bool

    var memoryFootprintMB: Double { Double(memoryFootprintBytes) / 1_048_576 }
    var memoryAvailableMB: Double { Double(memoryAvailableBytes) / 1_048_576 }
    var memoryTotalMB: Double { Double(memoryTotalBytes) / 1_048_576 }

    /// Short label for the UI and for the metrics backend's tag value.
    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Numeric form so the backend can graph/alert on it (0 = nominal … 3 = critical).
    var thermalLevel: Int {
        switch thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return -1
        }
    }
}

enum SystemMetricsReader {

    /// Take a reading. Safe from any thread; each field degrades to 0/nil rather than throwing.
    static func sample() -> SystemMetrics {
        SystemMetrics(
            memoryFootprintBytes: memoryFootprint(),
            memoryAvailableBytes: UInt64(os_proc_available_memory()),
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            cpuPercent: cpuUsagePercent(),
            thermalState: ProcessInfo.processInfo.thermalState,
            batteryLevel: batteryLevel(),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    // MARK: - Memory

    /// `phys_footprint` from TASK_VM_INFO — the same accounting jetsam uses, so it is the number
    /// to watch next to `os_proc_available_memory()`. (`resident_size` overstates and misleads.)
    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    // MARK: - CPU

    /// Sum `cpu_usage` across our live threads. Each thread reports 0…TH_USAGE_SCALE for one core,
    /// so a fully-busy 2-thread workload reads ~200%. Idle threads are skipped.
    private static func cpuUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }

        // task_threads allocates; we own the memory and must give it back.
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }

    // MARK: - Battery

    private static func batteryLevel() -> Float? {
        // Enabling monitoring is idempotent and cheap; without it the level reads -1.
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : level
    }
}
