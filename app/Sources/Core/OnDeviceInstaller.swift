// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import LauncherCore

/// Installs a signed IPA on this very device, with no server in between.
///
/// The app already has a loopback tunnel to the device's own services (10.7.0.1, see TunnelManager) and a pairing file (see OnDevicePairing). With those, the
/// same remote-pairing handshake the JIT helper uses opens iOS's file-transfer (AFC) and installer (installation_proxy) services. The signed build is copied to
/// the device's staging folder and the installer is told to install it, which is what a computer does over USB. Nothing is uploaded anywhere.
///
/// The calls are idevice's C functions (declared in IdeviceInstall.h). They block, so all of it runs off the main actor.
struct OnDeviceInstaller: DeviceInstaller {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// The tunnel's address for the device itself and the port its remote-pairing service answers on (the same ones the JIT helper uses).
    private static let deviceAddress = "10.7.0.1"
    private static let devicePort: UInt16 = 49152
    private static let hostName = "Porthole"
    private static let stagingDirectory = "PublicStaging"
    private static let chunk = 1 << 20

    /// What the blocking part is doing, so the waiting side can tell "slow" from "iOS is not answering".
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var _last = Date(), _installStarted: Date?, _reports = 0
        func touch() { lock.lock(); _last = Date(); lock.unlock() }
        func installBegan() { lock.lock(); _installStarted = Date(); _last = Date(); lock.unlock() }
        func reported() { lock.lock(); _reports += 1; _last = Date(); lock.unlock() }
        var snapshot: (last: Date, installStarted: Date?, reports: Int) { lock.lock(); defer { lock.unlock() }; return (_last, _installStarted, _reports) }
    }

    /// Everything the installer does goes to the app's log (it is the only way to tell why an install did nothing).
    private static func log(_ text: String) {
        DispatchQueue.main.async { LogStore.shared.log("[device-install] " + text) }
    }

    /// How long iOS may stay silent after the install request before the attempt is given up.
    private static let silenceLimit: TimeInterval = 90

    func isAvailable() async -> Bool {
        guard #available(iOS 17, *) else { return false }
        return BuiltinJIT.hasPairing
    }

    func install(ipa: URL, progress: @escaping @Sendable (String, Double) -> Void) async throws {
        let size = (try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Self.log("start: \(size / 1_048_576) MB")
        progress("Starting the connection", 0)
        let tunnel = await MainActor.run { TunnelManager.shared }
        let began = Date()
        // Porthole's own tunnel is part of the app that is being replaced: when iOS starts replacing the app it stops the app's extensions too, and
        // that would cut the very connection the install runs over. A VPN from another app (LocalDevVPN uses the same address) does not have that
        // problem, so when one is already on it is used instead of Porthole's.
        let usingOtherVPN = await Task.detached { Self.deviceReachable() }.value
        if usingOtherVPN {
            Self.log("the device is already reachable (another VPN is on): using it, not Porthole's own tunnel")
        } else {
            // While Porthole updates itself the update popup shows the question inside itself; any other install keeps the separate window.
            let hosted = await MainActor.run { UpdateService.current?.pipeline.job?.appID == UpdateService.appID }
            // Cellular data would stop the tunnel from working. The download is done, and the install needs no internet: ask first, switch it off once the tunnel is up.
            guard await CellularGuard.shared.confirm(for: "install the update", hosted: hosted) else {
                throw Failure("Cancelled: cellular data stays on, and the update was not installed. Join Wi-Fi, or allow it to be switched off for a moment.")
            }
            guard await VPNGuard.shared.confirmPause(for: "install the update", until: "the update has installed", hosted: hosted) else {
                await CellularGuard.shared.disarm()
                throw Failure("Cancelled: your VPN stays on, and the update was not installed.")
            }
            do { try await tunnel.connect() } catch { Self.log("tunnel failed: \(ErrorText.plain(error))"); throw error }
            Self.log(String(format: "Porthole's own tunnel up in %.1f s", Date().timeIntervalSince(began)))
        }
        defer { if !usingOtherVPN { Task { @MainActor in TunnelManager.shared.disconnect() } } }
        let activity = Activity()
        do {
            if await CellularGuard.shared.armed {
                guard await CellularGuard.shared.switchOff() else {
                    throw Failure(await CellularGuard.shared.lastProblem ?? "Cellular data could not be switched off, so the install cannot reach the device.")
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.detached(priority: .userInitiated) { try Self.run(ipa: ipa, progress: progress, activity: activity) }.value
                }
                group.addTask {
                    // Watches the blocking part: says what it is waiting for, and gives up if iOS stays silent.
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let now = activity.snapshot
                        guard let started = now.installStarted else { continue }
                        let waited = Int(Date().timeIntervalSince(started))
                        if now.reports == 0 { progress("Installing: waiting for iOS to start (\(waited) s)", 0) }
                        if Date().timeIntervalSince(now.last) > Self.silenceLimit {
                            Self.log("gave up: no answer from iOS for \(Int(Self.silenceLimit)) s (reports so far: \(now.reports))")
                            throw Failure("iOS did not answer the install request for \(Int(Self.silenceLimit)) seconds, so Porthole stopped waiting. Unlock the device and try again; if it keeps happening, send the log.")
                        }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            Self.log("failed: \(ErrorText.plain(error))")
            await CellularGuard.shared.restoreNow()          // the update did not install: cellular data comes back on now (after a successful install the app restarts and does it then)
            throw error
        }
        Self.log("finished")
    }

    /// Whether the device's own address answers right now, which means some VPN already routes it. Gives up after a second and a half.
    private static func deviceReachable() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = devicePort.bigEndian
        guard inet_pton(AF_INET, deviceAddress, &address.sin_addr) == 1 else { return false }
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&poll, 1, 1500) > 0 else { return false }
        var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
    }

    // MARK: The blocking part

    private static func run(ipa: URL, progress: @escaping @Sendable (String, Double) -> Void, activity: Activity) throws {
        var pairing: OpaquePointer?
        try check(try BuiltinJIT.withPairingFile { file in file.path.withCString { rp_pairing_file_read($0, &pairing) } }, "Couldn't read the pairing file")
        defer { rp_pairing_file_free(pairing) }

        progress("Connecting to this iPhone", 0)
        var adapter: OpaquePointer?, handshake: OpaquePointer?
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = devicePort.bigEndian
        guard inet_pton(AF_INET, deviceAddress, &address.sin_addr) == 1 else { throw Failure("Bad device address.") }
        try check(hostName.withCString { host in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), host, pairing, nil, nil, &adapter, &handshake)
                }
            }
        }, "Couldn't reach the device's installer. Is the tunnel on and the pairing file current?")
        // A way of asking that never got an answer may still be blocked on this connection: then it is left open instead of freed under it.
        var abandoned = false
        defer { if !abandoned { rsd_handshake_free(handshake); _ = adapter_close(adapter); adapter_free(adapter) } }
        log("connected to the device")
        activity.touch()

        // 1. Copy the build to the device's staging folder.
        var afc: OpaquePointer?
        try check(afc_client_connect_rsd(adapter, handshake, &afc), "Couldn't open the device's file service")
        defer { afc_client_free(afc) }
        let name = "f4-\(UUID().uuidString.prefix(8)).ipa"
        let remote = "\(stagingDirectory)/\(name)"
        // The folder usually exists already; an error here only matters if the copy below fails too.
        idevice_error_free(stagingDirectory.withCString { afc_make_directory(afc, $0) })
        let copyStart = Date()
        // Several connections each write a quarter of the file at once: one connection waits for iOS to acknowledge every 64 KB, which leaves the link idle most of
        // the time. If that goes wrong in any way, the whole file is copied over the one connection as before.
        do {
            try sendParallel(ipa, to: remote, adapter: adapter, handshake: handshake, first: afc, progress: { stage, fraction in activity.touch(); progress(stage, fraction) })
            log(String(format: "copied to %@ over %d connections in %.1f s", remote, streams, Date().timeIntervalSince(copyStart)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("copying over \(streams) connections failed (\(ErrorText.plain(error))); copying over one")
            let again = Date()
            try send(ipa, to: remote, over: afc, progress: { stage, fraction in activity.touch(); progress(stage, fraction) })
            log(String(format: "copied to %@ over one connection in %.1f s", remote, Date().timeIntervalSince(again)))
        }
        defer { if !abandoned { idevice_error_free(remote.withCString { afc_remove_path(afc, $0) }) } }

        // 2. Ask iOS to install it. A plain Install got no answer at all on a real device, so the ways a developer-signed build is normally installed
        // are tried in turn, each on its own connection, moving on when one gets no answer. The first that gets an answer is followed to the end.
        progress("Installing", 0)
        struct Attempt { let command: String; let developer: Bool }
        let attempts = [Attempt(command: "Install", developer: true), Attempt(command: "Upgrade", developer: true), Attempt(command: "Upgrade", developer: false)]
        nonisolated(unsafe) let linkAdapter = adapter, linkHandshake = handshake
        var lastFailure: Error?
        for (index, attempt) in attempts.enumerated() {
            log("attempt \(index + 1) of \(attempts.count): \(attempt.command)\(attempt.developer ? " as a developer package" : " with no options")")
            activity.installBegan()
            let state = AttemptState()
            let thread = Thread {
                do {
                    try runCommand(attempt.command, developer: attempt.developer, adapter: linkAdapter, handshake: linkHandshake, remote: remote) { stage, fraction in
                        state.reported(); activity.reported()
                        let percent = Int(fraction * 100)
                        if percent % 10 == 0 { log("iOS reports \(percent)%") }
                        progress(stage, fraction)
                    }
                    state.finish(nil)
                } catch { state.finish(error) }
            }
            thread.stackSize = 4 << 20
            thread.start()
            let began = Date()
            waiting: while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = state.snapshot
                if now.finished {
                    if let error = now.error {
                        log("attempt \(index + 1) ended with an error after \(now.reports) report(s): \(ErrorText.plain(error))")
                        lastFailure = error
                        if now.reports > 0 { throw error }          // iOS did answer and said no: another way will not change that
                        break waiting
                    }
                    log("iOS says the install is complete (attempt \(index + 1))")
                    progress("Installed", 1)
                    return
                }
                if now.reports == 0, Date().timeIntervalSince(began) > attemptSilence {
                    log("attempt \(index + 1): no answer after \(Int(attemptSilence)) s, trying the next way")
                    abandoned = true
                    break waiting
                }
            }
        }
        throw lastFailure ?? Failure("iOS did not answer any way of asking it to install. Unlock the device and try again; if it keeps happening, send the log.")
    }

    /// How long one way of asking may get no answer before the next is tried.
    private static let attemptSilence: TimeInterval = 25

    private final class AttemptState: @unchecked Sendable {
        private let lock = NSLock()
        private var _reports = 0, _finished = false, _error: Error?
        func reported() { lock.lock(); _reports += 1; lock.unlock() }
        func finish(_ error: Error?) { lock.lock(); _finished = true; _error = error; lock.unlock() }
        var snapshot: (reports: Int, finished: Bool, error: Error?) { lock.lock(); defer { lock.unlock() }; return (_reports, _finished, _error) }
    }

    /// One Install or Upgrade request on a connection of its own. Blocks until iOS says it is done (or it never does).
    private static func runCommand(_ command: String, developer: Bool, adapter: OpaquePointer?, handshake: OpaquePointer?, remote: String,
                                   onReport: @escaping @Sendable (String, Double) -> Void) throws {
        var installer: OpaquePointer?
        try check(installation_proxy_connect_rsd(adapter, handshake, &installer), "Couldn't open the device's installer")
        defer { installation_proxy_client_free(installer) }
        var options: UnsafeMutableRawPointer?
        if developer {
            // {"PackageType": "Developer"}: what sideloading tools send for a build signed with a developer certificate. (Handed to the library and
            // not freed here: a few bytes, and freeing something the library may also free would crash.)
            let dictionary = plist_new_dict()
            "PackageType".withCString { key in "Developer".withCString { value in plist_dict_set_item(dictionary, key, plist_new_string(value)) } }
            options = UnsafeMutableRawPointer(dictionary)
        }
        let box = Unmanaged.passRetained(ProgressBox(onReport))
        defer { box.release() }
        let callback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { percent, context in
            guard let context else { return }
            Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report("Installing", min(1, Double(percent) / 100))
        }
        try check(remote.withCString { path in
            command == "Install" ? installation_proxy_install_with_callback(installer, path, options, callback, box.toOpaque())
                                 : installation_proxy_upgrade_with_callback(installer, path, options, callback, box.toOpaque())
        }, "iOS refused the install")
    }

    private final class ProgressBox: @unchecked Sendable {
        let report: @Sendable (String, Double) -> Void
        init(_ report: @escaping @Sendable (String, Double) -> Void) { self.report = report }
    }

    /// How many connections the copy uses.
    private static let streams = 4

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var _done: Int64 = 0, _error: Error?
        func add(_ bytes: Int) -> Int64 { lock.lock(); _done += Int64(bytes); defer { lock.unlock() }; return _done }
        func fail(_ error: Error) { lock.lock(); if _error == nil { _error = error }; lock.unlock() }
        var failure: Error? { lock.lock(); defer { lock.unlock() }; return _error }
        var done: Int64 { lock.lock(); defer { lock.unlock() }; return _done }
    }

    /// The same file as `send`, written by several connections to the device's file service at once, each to its own range of the staging file.
    private static func sendParallel(_ file: URL, to remote: String, adapter: OpaquePointer?, handshake: OpaquePointer?, first: OpaquePointer?,
                                     progress: @escaping @Sendable (String, Double) -> Void) throws {
        let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > Int64(streams) * Int64(chunk) else { throw Failure("too small to split") }
        var clients: [OpaquePointer?] = [first]
        var handles: [OpaquePointer?] = []
        // Only what this function opened is closed here; the first connection belongs to the caller.
        defer {
            for handle in handles { idevice_error_free(afc_file_close(handle)) }
            for client in clients.dropFirst() { afc_client_free(client) }
        }
        var firstHandle: OpaquePointer?
        try check(remote.withCString { afc_file_open(first, $0, 3, &firstHandle) }, "Couldn't create the staging file on the device")
        handles.append(firstHandle)
        for _ in 1..<streams {
            var client: OpaquePointer?
            try check(afc_client_connect_rsd(adapter, handshake, &client), "Couldn't open another connection to the device's file service")
            clients.append(client)
            var handle: OpaquePointer?
            try check(remote.withCString { afc_file_open(client, $0, 2, &handle) }, "Couldn't open the staging file again")
            handles.append(handle)
        }

        // Ranges: equal parts, each a whole number of chunks except the last.
        let part = ((size / Int64(streams)) / Int64(chunk) + 1) * Int64(chunk)
        let tally = Tally()
        let group = DispatchGroup()
        for index in 0..<streams {
            let start = Int64(index) * part
            let end = min(size, start + part)
            if start >= end { continue }
            nonisolated(unsafe) let handle = handles[index]
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                do {
                    var position: Int64 = 0
                    try check(afc_file_seek(handle, start, 0, &position), "Moving within the staging file failed")
                    let reader = try FileHandle(forReadingFrom: file)
                    defer { try? reader.close() }
                    try reader.seek(toOffset: UInt64(start))
                    var at = start
                    while at < end {
                        if tally.failure != nil { return }
                        let want = Int(min(Int64(chunk), end - at))
                        guard let data = try reader.read(upToCount: want), !data.isEmpty else { throw Failure("The file ended early.") }
                        try check(data.withUnsafeBytes { raw in
                            afc_file_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
                        }, "Copying to the device failed")
                        at += Int64(data.count)
                        let total = tally.add(data.count)
                        progress("Sending to the installer", Double(total) / Double(size))
                    }
                } catch { tally.fail(error) }
            }
            thread.stackSize = 2 << 20
            thread.start()
        }
        group.wait()
        if let error = tally.failure { throw error }
        guard tally.done == size else { throw Failure("Only \(tally.done) of \(size) bytes were copied.") }
        // Close here (not in the defer) so a failed close is reported.
        let open = handles; handles = []
        for handle in open { try check(afc_file_close(handle), "Finishing the copy failed") }
    }

    private static func send(_ file: URL, to remote: String, over afc: OpaquePointer?, progress: @Sendable (String, Double) -> Void) throws {
        let total = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var handle: OpaquePointer?
        try check(remote.withCString { afc_file_open(afc, $0, 3, &handle) }, "Couldn't create the staging file on the device")
        var sent = 0.0, closed = false
        defer { if !closed { idevice_error_free(afc_file_close(handle)) } }
        while true {
            try Task.checkCancellation()
            guard let data = try reader.read(upToCount: chunk), !data.isEmpty else { break }
            try check(data.withUnsafeBytes { raw in
                afc_file_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }, "Copying to the device failed")
            sent += Double(data.count)
            progress("Sending to the installer", total > 0 ? sent / total : 0)
        }
        closed = true
        try check(afc_file_close(handle), "Finishing the copy failed")
    }

    /// Turns a returned error into a thrown one and frees it.
    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) throws {
        guard let error else { return }
        let detail = error.pointee.message.map { String(cString: $0) }
        let code = error.pointee.code
        idevice_error_free(error)
        log("error: \(fallback) code=\(code) message=\(detail ?? "-")")
        throw Failure("\(fallback)\(detail.map { " (\($0))" } ?? " (error \(code))").")
    }
}
