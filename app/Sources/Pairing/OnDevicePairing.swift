// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import AVFAudio
import BackgroundTasks
import UserNotifications
import Observation

/// Credits for the pairing feature. The conversation with the iPhone was worked out by others and re-implemented here in Swift.
enum PairingCredits {
    static let text = "On-device pairing follows the protocol documented by the idevice project and shown working by StikPair. The code in this app is a separate Swift implementation."
}

/// Drives the on-device pairing: runs the pairable host, keeps the app alive while the person goes to Settings, shows the code, and imports the
/// resulting pairing file so In-app JIT works.
@MainActor
@Observable
final class OnDevicePairing {
    static let shared = OnDevicePairing()

    enum Phase: Equatable {
        case idle
        case starting
        case waiting                     // advertising; waiting for the person to tap "Pair with ..." in Settings
        case showPIN(String)
        case success(String)             // the paired device's name
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The last attempt failed but the app is still listening: the person can tap "Pair with ..." in Settings again.
    private(set) var note: String?
    /// Step-by-step trace of the conversation with the iPhone (for diagnosing a failed pairing).
    private(set) var trace: [String] = []
    /// Lets the screen know the file was imported (so it can refresh "pairing file imported").
    private(set) var importedCount = 0

    /// Pairing from the iPhone's own Settings exists from iOS 27.
    static var isSupported: Bool { if #available(iOS 27.0, *) { true } else { false } }
    /// The name shown in Settings after "Pair with".
    static let hostName = "Porthole"
    nonisolated static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "site.portholehq.app") + ".pairing" }

    var isRunning: Bool { switch phase { case .starting, .waiting, .showPIN: true; default: false } }

    private var host: RemotePairingHost?
    private var runTask: Task<Void, Never>?
    private let keepAlive = SilentAudioKeepAlive()
    private var continuedTask: AnyObject?          // BGContinuedProcessingTask (iOS 26+)

    // MARK: Background task registration (must happen before the app finishes launching)

    nonisolated static func registerBackgroundTask() {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: DispatchQueue.main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated { OnDevicePairing.shared.adopt(task) }
        }
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.fail("The app ran out of background time before the iPhone connected. Tap Start and go to Settings straight away.")
            }
        }
    }

    // MARK: Control

    func start() {
        guard Self.isSupported, !isRunning else { return }
        phase = .starting
        note = nil
        trace = []
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        keepAlive.start()
        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: "Pairing", subtitle: "Waiting for this iPhone to connect…")
            request.strategy = .queue
            try? BGTaskScheduler.shared.submit(request)
        }

        let host = RemotePairingHost(displayName: Self.hostName)
        self.host = host
        host.onAdvertising = { [weak self] in Task { @MainActor in if self?.phase == .starting { self?.phase = .waiting } } }
        host.onPIN = { [weak self] pin in Task { @MainActor in self?.presentPIN(pin) } }
        host.onLog = { [weak self] line in
            Task { @MainActor in
                LogStore.shared.log("[pairing] \(line)")
                self?.trace.append(line)
                if let n = self?.trace.count, n > 60 { self?.trace.removeFirst(n - 60) }
            }
        }
        host.onAttemptFailed = { [weak self] why in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.note = why
                self.phase = .waiting
            }
        }
        host.onBlocked = { [weak self] why in
            Task { @MainActor in
                guard let self, self.phase == .starting || self.phase == .waiting else { return }
                self.fail("Pairing could not start (\(why)). Allow Local Network for this app in Settings › Privacy & Security › Local Network, and make sure Wi-Fi is on.")
            }
        }
        runTask = Task { [weak self] in
            do {
                let result = try await host.run()
                await self?.finish(result)
            } catch {
                await self?.fail((error as? LocalizedError)?.errorDescription ?? ErrorText.plain(error))
            }
        }
    }

    func cancel() {
        host?.cancel()
        runTask?.cancel()
        teardown()
        phase = .idle
    }

    func reset() { if !isRunning { phase = .idle } }

    // MARK: Results

    private func presentPIN(_ pin: String) {
        guard isRunning else { return }
        phase = .showPIN(pin)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = 50
            task.updateTitle("Pairing", subtitle: "Enter code \(pin) on this iPhone")
        }
        notify(id: "f4.pairing.pin", title: "Pairing code: \(pin)", body: "Type \(pin) on the screen that asks for it.")
    }

    private func finish(_ result: RemotePairingHost.Result) {
        defer { teardown() }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
            try result.pairingFile.write(to: url, options: [.atomic, .completeFileProtection])
            defer { try? FileManager.default.removeItem(at: url) }
            try BuiltinJIT.importPairing(from: url)
            JITMethod.current = .inApp
            importedCount += 1
            phase = .success(result.deviceName)
            LogStore.shared.log("[pairing] paired and imported the pairing file", level: .success)
            notify(id: "f4.pairing.done", title: "Pairing complete", body: "Return to the app. JIT can now be switched on from inside it.")
            if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask { task.progress.completedUnitCount = 100 }
        } catch {
            phase = .failed("Paired, but the pairing file could not be saved: \(ErrorText.plain(error))")
        }
    }

    private func fail(_ message: String) {
        guard phase != .idle else { return }
        host?.cancel()
        teardown()
        phase = .failed(message)
        LogStore.shared.log("[pairing] \(message)", level: .error)
    }

    private func teardown() {
        keepAlive.stop()
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask { task.setTaskCompleted(success: phase != .idle) }
        continuedTask = nil
        host = nil
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Plays silence so iOS keeps the app running while the person is in Settings. Used only while pairing.
@MainActor
final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = engine.outputNode.inputFormat(forBus: 0)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity          // zero-filled = silence
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
        } catch { running = false }
    }

    func stop() {
        guard running else { return }
        player.stop(); engine.stop(); engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        running = false
    }
}
