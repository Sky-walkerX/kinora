// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Darwin
import Foundation
import Observation

/// What Kinora's wallpaper costs right now: CPU and energy of the plug-in process, which does
/// all the decoding and drawing. Sampled every two seconds while the window is open.
@MainActor @Observable final class EnergyMonitor {
    struct Reading: Equatable {
        /// Percent of one CPU core.
        var cpuPercent: Double
        /// Average power over the last interval, in milliwatts; nil where macOS doesn't report energy.
        var milliwatts: Double?
    }

    private(set) var reading: Reading?
    private(set) var running = false
    private var timer: Timer?
    private var last: (pid: pid_t, cpu: UInt64, energy: UInt64, at: UInt64)?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let pid = Self.plugInPID(), let usage = Self.usage(of: pid) else {
            running = false
            reading = nil
            last = nil
            return
        }
        running = true
        let now = mach_continuous_time()
        let cpu = usage.ri_user_time + usage.ri_system_time
        defer { last = (pid, cpu, usage.ri_energy_nj, now) }
        guard let last, last.pid == pid, now > last.at else { return }
        let elapsed = Self.nanoseconds(now - last.at)
        let cpuPercent = Double(Self.nanoseconds(cpu &- last.cpu)) / Double(elapsed) * 100
        let energy = usage.ri_energy_nj >= last.energy && usage.ri_energy_nj > 0 ? Double(usage.ri_energy_nj - last.energy) : nil
        reading = Reading(cpuPercent: max(0, cpuPercent), milliwatts: energy.map { $0 / Double(elapsed) * 1000 })
    }

    // MARK: - Process lookup

    static func plugInPID() -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("KinoraWallpaper.appex/Contents/MacOS/KinoraWallpaper") { return pid }
        }
        return nil
    }

    static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return status == 0 ? info : nil
    }

    /// rusage times are in Mach absolute time units, which are not nanoseconds on Apple silicon.
    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return ticks * UInt64(base.numer) / UInt64(max(1, base.denom))
    }
}
