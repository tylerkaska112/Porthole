// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import UIKit
import Metal
import os

/// One reading of how the phone and the game are doing.
struct TelemetrySample {
    var time = Date()
    var fps = 0.0            // presents per second over the last interval
    var lowFPS = 0.0         // worst of the last 30 readings
    var cpuPercent = 0.0     // all of this app's threads; 100 = one full core
    var threads = 0
    var footprintMB = 0.0    // what iOS counts against the app (phys_footprint)
    var availableMB = 0.0    // memory left before iOS would terminate the app
    var gpuMB = 0.0          // Metal allocations
    var thermal = "cool"
    var battery: Double?     // 0...1
    var drainPerHour: Double?// percentage points per hour since the game started
    var lowPowerMode = false
    var mode = ""
    var gpuBusyPercent: Double?   // share of the last second the GPU was busy; nil = not measured (only while the full readout is shown)
    var gpuFrameMs: Double?       // GPU time per presented frame
    var topThreadPercent: Double? // the busiest thread, 100 = one full core: a game held back by one thread while the total stays low
    var engine = EngineStats()    // swap file, memory split and page-in rate, from the log (only while the full readout is shown)

    var frameMs: Double { fps > 0 ? 1000 / fps : 0 }

    var compact: String {
        String(format: "%.0f fps | %.0f%% cpu | %.1f GB | %@", fps, cpuPercent, footprintMB / 1024, thermal)
            + (battery.map { String(format: " | %.0f%%", $0 * 100) } ?? "")
    }

    var full: String {
        var lines = [String(format: "FPS %.0f (low %.0f)   frame %.1f ms", fps, lowFPS, frameMs)]
        lines.append(String(format: "CPU %.0f%% on %d threads", cpuPercent, threads))
        lines.append(String(format: "App mem %.2f GB   free %.2f GB   GPU %.2f GB", footprintMB / 1024, availableMB / 1024, gpuMB / 1024))
        var heat = "Heat: \(thermal)"
        if let battery {
            heat += String(format: "   Battery %.0f%%", battery * 100)
            if let drainPerHour { heat += String(format: " (%@%.0f%%/h)", drainPerHour > 0 ? "-" : "+", abs(drainPerHour)) }
        }
        if lowPowerMode { heat += "   Low Power Mode" }
        lines.append(heat)
        if let gpuBusyPercent {
            lines.append(String(format: "GPU busy %.0f%%", gpuBusyPercent) + (gpuFrameMs.map { String(format: " (%.1f ms a frame)", $0) } ?? "") + (topThreadPercent.map { String(format: "   busiest thread %.0f%%", $0) } ?? ""))
        } else if let topThreadPercent { lines.append(String(format: "Busiest thread %.0f%%", topThreadPercent)) }
        if let used = engine.swapFileUsedMB, let cap = engine.swapFileCapMB, cap > 0 {
            let percent = Double(used) / Double(cap) * 100
            var swap = String(format: "Swap file %.2f of %.2f GB (%.0f%%)", Double(used) / 1024, Double(cap) / 1024, percent)
            if percent >= 90 { swap += "  FULL SOON" }
            lines.append(swap)
            var detail = ""
            if let backed = engine.swapBackedMB { detail += String(format: "in swap %.2f GB", Double(backed) / 1024) }
            if let peak = engine.swapPeakMB { detail += String(format: "%@peak %.2f GB", detail.isEmpty ? "" : "   ", Double(peak) / 1024) }
            if let refused = engine.swapRefused, refused > 0 { detail += "   refused \(refused)" }
            if let coverage = engine.swapCoverage { detail += "   covers \(coverage)" }
            if !detail.isEmpty { lines.append(detail) }
        }
        if engine.compressedMB != nil || engine.readMBPerSecond != nil {
            var memory = ""
            if let c = engine.compressedMB { memory += String(format: "Compressed %.2f GB", Double(c) / 1024) }
            if let e = engine.externalMB { memory += String(format: "%@file-backed %.2f GB", memory.isEmpty ? "" : "   ", Double(e) / 1024) }
            if let r = engine.readMBPerSecond { memory += String(format: "%@paging in %.1f MB/s", memory.isEmpty ? "" : "   ", r) }
            if !memory.isEmpty { lines.append(memory) }
        }
        lines.append("Mode: \(mode)")
        return lines.joined(separator: "\n")
    }

    var csvLine: String {
        let f = Self.iso(time)
        return String(format: "%@,%.1f,%.1f,%.0f,%d,%.0f,%.0f,%.0f,%@,%@,%@,%d,%@",
                      f, fps, lowFPS, cpuPercent, threads, footprintMB, availableMB, gpuMB, thermal,
                      battery.map { String(format: "%.3f", $0) } ?? "", drainPerHour.map { String(format: "%.1f", $0) } ?? "",
                      lowPowerMode ? 1 : 0, mode)
    }
    /// "2026-10-07T13:58:26Z" from the C library. An ISO8601DateFormatter made every second here went through ICU, which crashed (a read of unmapped memory inside
    /// SimpleDateFormat) in the middle of a game on 2026-10-07; the same thing had already happened after a game ended (see SaveBackup.fileStamp).
    static func iso(_ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970), parts = tm()
        gmtime_r(&t, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%SZ", &parts)
        return String(cString: buffer)
    }
    static let csvHeader = "time,fps,fps_low,cpu_pct,threads,app_mb,free_mb,gpu_mb,thermal,battery,drain_pct_per_hour,low_power,mode"
}

/// Samples once a second while a game runs. Shown in the HUD, logged every 15 s, and appended every 5 s to `Documents/telemetry.csv`
/// (visible in the Files app) so a whole session can be looked at afterwards.
final class Telemetry {
    static let shared = Telemetry()
    private(set) var latest = TelemetrySample()
    var onSample: ((TelemetrySample) -> Void)?
    /// A sentence for the person when the game is close to running out of memory (see `checkAlerts`).
    var onAlert: ((String) -> Void)?
    private var alertsShown = 0, lastAlert = Date.distantPast, lastEngine = EngineStats()

    private var timer: Timer?
    private var lastPresents: UInt64 = 0
    private var lastTick = Date()
    private var recentFPS: [Double] = []
    private var ticks = 0
    // Whole-session tallies for compatibility reports (see CompatStore).
    private var sessionFPS: [Double] = []
    private var sessionHeat = 0
    private var sessionStart = Date()
    /// Called about once a minute while sampling, with the session so far.
    var onCheckpoint: ((CompatSessionStats) -> Void)?
    private var startBattery: (level: Double, time: Date)?
    private let device = MTLCreateSystemDefaultDevice()
    /// The HUD sets this while the full readout is on: the GPU's busy time is only measured then (it adds a handler to every command buffer).
    static var detailWanted = false { didSet { if !detailWanted && oldValue { madeira_gpu_meter_enable(0) } } }
    private var gpuMeterOn = false, lastGPUBusy = 0.0, lastGPUBuffers: UInt64 = 0
    private let csvURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("telemetry.csv")
    // Memory over the session, for the `[mem-summary]` line and the pressure log (0.50.120).
    private var peakFootprintMB = 0.0, peakGPUMB = 0.0, minFreeMB = Double.greatestFiniteMagnitude
    private var secondsBelow1GB = 0, secondsBelow500MB = 0
    private var pressureEvents = 0, relieved = 0
    private var inRedZone = false
    private var pressureSource: DispatchSourceMemoryPressure?

    func start() {
        guard timer == nil else { return }
        Task { @MainActor in CPUClampMonitor.shared.start() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        lastPresents = madeira_frame_count(); lastTick = Date(); recentFPS = []; ticks = 0
        sessionFPS = []; sessionHeat = 0; sessionStart = Date()
        let level = Double(UIDevice.current.batteryLevel)
        startBattery = level >= 0 ? (level, Date()) : nil
        prepareCSV()
        peakFootprintMB = 0; peakGPUMB = 0; minFreeMB = .greatestFiniteMagnitude
        secondsBelow1GB = 0; secondsBelow500MB = 0; pressureEvents = 0; relieved = 0; inRedZone = false
        alertsShown = 0; lastAlert = .distantPast; lastEngine = EngineStats()
        watchMemoryPressure()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    /// iOS tells an app when memory runs short (warning, then critical) well before it ends the app. Before 0.50.120 nothing here listened.
    /// What happens: one `[mem-pressure]` line with the numbers, and the host's malloc caches (freed memory it kept for itself) go back to
    /// the system. That touches no game memory. The guest's own memory is the engine's (swap tier, video budget), not changed here.
    private func watchMemoryPressure() {
        pressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            let event = source.data
            let name = event.contains(.critical) ? "CRITICAL" : event.contains(.warning) ? "warning" : "back to normal"
            self.pressureEvents += event.contains(.normal) ? 0 : 1
            var freed = 0
            if !event.contains(.normal) { freed = Int(malloc_zone_pressure_relief(nil, 0)); self.relieved += freed }
            LogStore.shared.log(String(format: "[mem-pressure] %@: app %.0f MB, free %.0f MB, gpu %.0f MB; malloc gave back %d MB",
                                       name, Self.footprintMB(), Double(os_proc_available_memory()) / 1_048_576,
                                       Double(self.device?.currentAllocatedSize ?? 0) / 1_048_576, freed >> 20))
        }
        source.resume()
        pressureSource = source
    }

    /// The memory over the run so far. Written when the run ends and once a minute while it goes on, so a run that iOS ends still leaves its latest figures in the log
    /// (the Last time card reads the newest one).
    private func memorySummaryText() -> String {
        String(format: "[mem-summary] %d min: peak app %.0f MB, peak gpu %.0f MB, least free %.0f MB; %d s under 1 GB free, %d s under 500 MB; %d pressure events, malloc gave back %d MB",
               ticks / 60, peakFootprintMB, peakGPUMB, minFreeMB == .greatestFiniteMagnitude ? 0 : minFreeMB,
               secondsBelow1GB, secondsBelow500MB, pressureEvents, relieved >> 20)
    }

    func stop() {
        timer?.invalidate(); timer = nil; if gpuMeterOn { madeira_gpu_meter_enable(0); gpuMeterOn = false }
        Task { @MainActor in CPUClampMonitor.shared.stop() }
        pressureSource?.cancel(); pressureSource = nil
        if ticks > 0 { LogStore.shared.log(memorySummaryText()) }
    }

    private func sample() {
        let now = Date(), presents = madeira_frame_count()
        let seconds = now.timeIntervalSince(lastTick)
        let fps = seconds > 0 && presents >= lastPresents ? Double(presents - lastPresents) / seconds : 0
        lastPresents = presents; lastTick = now
        recentFPS.append(fps); if recentFPS.count > 30 { recentFPS.removeFirst() }

        var s = TelemetrySample()
        s.time = now; s.fps = fps; s.lowFPS = recentFPS.min() ?? fps
        (s.cpuPercent, s.threads) = Self.cpu()
        s.footprintMB = Self.footprintMB()
        s.availableMB = Double(os_proc_available_memory()) / 1_048_576
        s.gpuMB = Double(device?.currentAllocatedSize ?? 0) / 1_048_576
        let power = PowerManager.shared
        s.thermal = power.thermalName
        s.mode = "\(power.effective.title), \(power.effective.detail)" + (power.effective != power.chosen ? " (forced: hot)" : "")
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let level = Double(UIDevice.current.batteryLevel)
        if level >= 0 {
            s.battery = level
            if let start = startBattery, now.timeIntervalSince(start.time) >= 120 {
                s.drainPerHour = (start.level - level) * 100 / (now.timeIntervalSince(start.time) / 3600)
            }
        }
        if Self.detailWanted {
            if !gpuMeterOn { madeira_gpu_meter_enable(1); gpuMeterOn = true; lastGPUBusy = madeira_gpu_meter_busy_seconds(); lastGPUBuffers = madeira_gpu_meter_cmdbufs() }
            else {
                let busy = madeira_gpu_meter_busy_seconds(), buffers = madeira_gpu_meter_cmdbufs()
                let used = max(0, busy - lastGPUBusy)
                if buffers > lastGPUBuffers {
                    s.gpuBusyPercent = min(100, used / max(0.001, seconds) * 100)
                    if fps > 0 { s.gpuFrameMs = used * 1000 / (fps * seconds) }
                }
                lastGPUBusy = busy; lastGPUBuffers = buffers
            }
            s.topThreadPercent = Self.busiestThread()
            s.engine = EngineStats.read(from: LogStore.shared.logFileURL)
        } else { gpuMeterOn = false }
        latest = s
        peakFootprintMB = max(peakFootprintMB, s.footprintMB); peakGPUMB = max(peakGPUMB, s.gpuMB)
        if s.availableMB > 0 {
            minFreeMB = min(minFreeMB, s.availableMB)
            if s.availableMB < 1024 { secondsBelow1GB += 1 }
            if s.availableMB < 500 { secondsBelow500MB += 1 }
            // the red zone is entered below 400 MB free and left above 700 MB, so the log shows episodes, not a flicker
            if !inRedZone, s.availableMB < 400 { inRedZone = true; LogStore.shared.log(String(format: "[mem-pressure] red zone: only %.0f MB free, app %.0f MB, gpu %.0f MB", s.availableMB, s.footprintMB, s.gpuMB)) }
            else if inRedZone, s.availableMB > 700 { inRedZone = false; LogStore.shared.log(String(format: "[mem-pressure] red zone over: %.0f MB free", s.availableMB)) }
        }
        checkAlerts(s, now: now)
        if fps > 0, sessionFPS.count < 20_000 { sessionFPS.append(fps) }
        sessionHeat = max(sessionHeat, Self.heatLevel(s.thermal))
        ticks += 1
        if ticks % 60 == 0 { onCheckpoint?(sessionStats()) }
        if ticks % 5 == 0 { appendCSV(s.csvLine) }
        if ticks % 60 == 0 { LogStore.shared.log(memorySummaryText()) }
        if ticks % 15 == 0 { LogStore.shared.log("[telemetry] " + s.compact + String(format: " | free %.0f MB | gpu %.0f MB | %@", s.availableMB, s.gpuMB, s.mode)) }
        onSample?(s)
    }

    /// Tells the person, on screen, what is about to go wrong: the swap file nearly full, or the device nearly out of memory. Until 0.50.285 this was only a log line and
    /// "FULL SOON" in the expanded readout, so a stutter or a closed game came with no explanation. At most 4 times a session and 4 minutes apart.
    private func checkAlerts(_ s: TelemetrySample, now: Date) {
        if Self.detailWanted { lastEngine = s.engine }
        else if ticks % 10 == 5 { lastEngine = EngineStats.read(from: LogStore.shared.logFileURL) }
        guard alertsShown < 4, now.timeIntervalSince(lastAlert) > 240, ticks > 30 else { return }
        let swapOn = (lastEngine.swapFileCapMB ?? 0) > 0
        var text: String?
        if let used = lastEngine.swapFileUsedMB, let cap = lastEngine.swapFileCapMB, cap > 0, Double(used) / Double(cap) >= 0.92 {
            text = "Swap is almost full. If the game stutters or closes, raise Swap in this game's settings."
        } else if inRedZone {
            text = swapOn ? "Memory is almost full. Close other apps, or raise Swap in this game's settings."
                          : "Memory is almost full. Close other apps. If this keeps happening, turn on Swap in this game's settings."
        }
        guard let text else { return }
        alertsShown += 1; lastAlert = now
        LogStore.shared.log("[mem-alert] shown to the person: \(text)")
        onAlert?(text)
    }

    // MARK: This session, for compatibility reports

    private static let heatNames = ["cool", "warm", "hot", "critical"]
    private static func heatLevel(_ name: String) -> Int {
        switch name { case "warm": 1; case "hot": 2; case "very hot": 3; default: 0 }
    }

    /// Average and slowest-5% frame rate over the seconds in which the game drew anything, how long it ran, and how hot the phone got.
    func sessionStats() -> CompatSessionStats {
        let sorted = sessionFPS.sorted()
        let average = sorted.isEmpty ? nil : sorted.reduce(0, +) / Double(sorted.count)
        let low = sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.05))]
        return CompatSessionStats(fpsAvg: average.map { ($0 * 10).rounded() / 10 }, fpsLow: low.map { ($0 * 10).rounded() / 10 },
                                  minutes: Int(Date().timeIntervalSince(sessionStart) / 60), thermal: Self.heatNames[sessionHeat], samples: sorted.count)
    }

    /// One line per run for comparing builds and settings (the benchmark games): the same numbers every time, with the build and the graphics choices in effect. Nil when the game drew nothing.
    func benchmarkLine(game: String, settings: String) -> String? {
        guard !sessionFPS.isEmpty else { return nil }
        let sorted = sessionFPS.sorted()
        func low(_ share: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return String(format: "[benchmark] game=\"%@\" build=%@ engine=%@ seconds=%d fps-avg=%.1f fps-1pct-low=%.1f fps-5pct-low=%.1f fps-min=%.1f peak-app-mb=%.0f peak-gpu-mb=%.0f least-free-mb=%.0f heat=%@ | %@",
                      game, build, CompatEngine.id, Int(Date().timeIntervalSince(sessionStart)), average, low(0.01), low(0.05), sorted[0], peakFootprintMB, peakGPUMB,
                      minFreeMB == .greatestFiniteMagnitude ? 0 : minFreeMB, Self.heatNames[sessionHeat], settings)
    }

    // MARK: Measurements

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func cpu() -> (percent: Double, threads: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return (0, 0) }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 { total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100 }
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return (total, Int(count))
    }

    /// The busiest thread's share of one core (100 = one full core), from the threads' own usage figures.
    private static func busiestThread() -> Double? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
        var top = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 { top = max(top, Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100) }
        }
        return top
    }

    // MARK: CSV

    private func prepareCSV() {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: csvURL.path))?[.size] as? Int, size > 2_000_000 {
            let old = csvURL.deletingPathExtension().appendingPathExtension("prev.csv")
            try? fm.removeItem(at: old); try? fm.moveItem(at: csvURL, to: old)
        }
        if !fm.fileExists(atPath: csvURL.path) { try? (TelemetrySample.csvHeader + "\n").write(to: csvURL, atomically: true, encoding: .utf8) }
        appendCSV("# session start \(TelemetrySample.iso(Date()))")
    }

    private func appendCSV(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: csvURL), let data = (line + "\n").data(using: .utf8) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
}
