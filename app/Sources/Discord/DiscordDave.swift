// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Discord's end-to-end encryption for calls (DAVE), through Discord's own open-source library (libdave, MIT, with mlspp and OpenSSL; built by tools/build_dave.sh).
/// The library keeps the group's keys; this wraps its C interface for the voice connection. Nothing here talks to Discord.
final class DaveSession {
    private var handle: DAVESessionHandle?
    private(set) var userID: String

    init?(userID: String) {
        self.userID = userID
        handle = daveSessionCreate(nil, nil, { source, reason, _ in
            let s = source.map { String(cString: $0) } ?? "?", r = reason.map { String(cString: $0) } ?? "?"
            Task { @MainActor in LogStore.shared.log("[discord-dave] \(s): \(r)") }
        }, nil)
        if handle == nil { return nil }
    }

    deinit { if let handle { daveSessionDestroy(handle) } }

    /// Starts (or restarts) the session for a call: the protocol version the voice server chose, the channel's id and this account's id.
    func start(version: UInt16, channelID: UInt64) {
        guard let handle else { return }
        userID.withCString { daveSessionInit(handle, version, channelID, $0) }
    }

    func reset() { if let handle { daveSessionReset(handle) } }
    func setProtocolVersion(_ version: UInt16) { if let handle { daveSessionSetProtocolVersion(handle, version) } }
    var protocolVersion: UInt16 { handle.map { daveSessionGetProtocolVersion($0) } ?? 0 }

    func setExternalSender(_ bytes: Data) {
        guard let handle else { return }
        bytes.withUnsafeBytes { daveSessionSetExternalSender(handle, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
    }

    /// This device's key package, to send to the voice server (opcode 26).
    func keyPackage() -> Data? {
        guard let handle else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        daveSessionGetMarshalledKeyPackage(handle, &out, &length)
        return Self.take(out, length)
    }

    /// Proposals from the voice server (opcode 27, after its first byte which says append or revoke): the commit and welcome to answer with (opcode 28), or nil.
    func processProposals(_ bytes: Data, recognizedUserIDs: [String]) -> Data? {
        guard let handle else { return nil }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        Self.withCStrings(recognizedUserIDs) { ids, count in
            bytes.withUnsafeBytes { daveSessionProcessProposals(handle, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, ids, count, &out, &length) }
        }
        return Self.take(out, length)
    }

    enum CommitOutcome { case ok, failed, ignored }

    /// A commit the voice server announces (opcode 29) or the commit part of a welcome.
    func processCommit(_ bytes: Data) -> CommitOutcome {
        guard let handle else { return .failed }
        let result = bytes.withUnsafeBytes { daveSessionProcessCommit(handle, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        defer { if let result { daveCommitResultDestroy(result) } }
        guard let result else { return .failed }
        if daveCommitResultIsFailed(result) { return .failed }
        if daveCommitResultIsIgnored(result) { return .ignored }
        return .ok
    }

    /// A welcome (opcode 30): this device joins the group. False when the library refused it.
    func processWelcome(_ bytes: Data, recognizedUserIDs: [String]) -> Bool {
        guard let handle else { return false }
        var result: DAVEWelcomeResultHandle?
        Self.withCStrings(recognizedUserIDs) { ids, count in
            result = bytes.withUnsafeBytes { daveSessionProcessWelcome(handle, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, ids, count) }
        }
        guard let result else { return false }
        daveWelcomeResultDestroy(result)
        return true
    }

    /// The key ratchet of one user (this account for sending, another member for receiving). The caller destroys it with `DaveKeyRatchet`'s deinit.
    func keyRatchet(for userID: String) -> DaveKeyRatchet? {
        guard let handle else { return nil }
        let r = userID.withCString { daveSessionGetKeyRatchet(handle, $0) }
        return r.map(DaveKeyRatchet.init)
    }

    // MARK: helpers

    private static func take(_ pointer: UnsafeMutablePointer<UInt8>?, _ length: Int) -> Data? {
        guard let pointer else { return nil }
        defer { daveFree(pointer) }
        return length > 0 ? Data(bytes: pointer, count: length) : nil
    }

    private static func withCStrings(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, Int) -> Void) {
        let owned = strings.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        pointers.withUnsafeMutableBufferPointer { body($0.baseAddress ?? UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: 1), $0.count) }
    }
}

final class DaveKeyRatchet {
    let handle: DAVEKeyRatchetHandle
    init(_ handle: DAVEKeyRatchetHandle) { self.handle = handle }
    deinit { daveKeyRatchetDestroy(handle) }
}

enum DaveCheck {
    nonisolated(unsafe) static var lastDecryptNote: TimeInterval = 0
    /// Run once; the Discord page shows it.
    static let result: String = { let line = run(); Task { @MainActor in LogStore.shared.log("[discord-dave] \(line)") }; return line }()

    /// Proves the library is in the app and works: a session starts, makes a key package, and the frame encryptor sizes a frame. Returns a line for the screen and the log.
    static func run() -> String {
        daveSetLogSinkCallback { severity, _, _, message in
            guard severity.rawValue >= DAVE_LOGGING_SEVERITY_INFO.rawValue, let message else { return }
            let text = String(cString: message)
            // One line per second at most for the same complaint (frames from someone who has not switched on encryption yet come in dozens).
            if text.hasPrefix("Decrypt failed") {
                let now = Date().timeIntervalSince1970
                if now - DaveCheck.lastDecryptNote < 5 { return }
                DaveCheck.lastDecryptNote = now
            }
            Task { @MainActor in LogStore.shared.log("[discord-dave] library: \(text)") }
        }
        let supported = daveMaxSupportedProtocolVersion()
        guard let session = DaveSession(userID: "1") else { return "Could not start the encryption library." }
        session.start(version: supported, channelID: 1)
        let key = session.keyPackage()
        let encryptor = daveEncryptorCreate()
        defer { daveEncryptorDestroy(encryptor) }
        let size = daveEncryptorGetMaxCiphertextByteSize(encryptor, DAVE_MEDIA_TYPE_AUDIO, 100)
        guard let key, !key.isEmpty, size > 100 else { return "The encryption library started but did not make a key." }
        return "Ready: protocol version \(supported), key package \(key.count) bytes"
    }
}

/// Follows Discord's reference flow (libdave's samples/typescript/DaveSessionManager.ts) for one voice connection: what to do with each end-to-end-encryption message
/// the voice server sends, and what to answer. It does no network itself: the voice connection hands it messages and sends what `output` asks for.
final class DaveManager {
    /// What to send to the voice server.
    enum Output {
        case keyPackage(Data)             // opcode 26 (binary)
        case commitWelcome(Data)          // opcode 28 (binary)
        case readyForTransition(Int)      // opcode 23 (json)
        case invalidCommitWelcome(Int)    // opcode 31 (json)
    }

    var output: ((Output) -> Void)?
    /// A key ratchet for a user changed (nil: no encryption). The sound code uses these to encrypt this account's frames and decrypt the others'.
    var onRatchet: ((String, DaveKeyRatchet?, UInt16) -> Void)?
    /// A line for the log and the screen ("joined the encrypted group").
    var onStatus: ((String) -> Void)?
    private(set) var joined = false

    private let session: DaveSession
    private let selfID: String
    private let groupID: UInt64
    private var recognized = Set<String>()
    private var transitions: [Int: UInt16] = [:]
    private var latestPreparedVersion: UInt16 = 0

    init?(selfUserID: String, groupID: UInt64) {
        guard let session = DaveSession(userID: selfUserID) else { return nil }
        self.session = session
        self.selfID = selfUserID
        self.groupID = groupID
    }

    private var recognizedIDs: [String] { Array(recognized) + [selfID] }

    func createUser(_ id: String) { recognized.insert(id); setupRatchet(id, version: latestPreparedVersion) }
    func destroyUser(_ id: String) { recognized.remove(id) }

    /// Session Description (opcode 4) named a protocol version.
    func onSessionDescription(version: UInt16) { handleInit(version) }

    /// Opcode 21.
    func onPrepareTransition(id: Int, version: UInt16) { log("prepare transition \(id), version \(version)"); prepareRatchets(id, version); readyIfNeeded(id) }

    /// Opcode 22.
    func onExecuteTransition(id: Int) { log("execute transition \(id)"); executeTransition(id) }

    /// Opcode 24.
    func onPrepareEpoch(epoch: Int, version: UInt16) {
        log("prepare epoch \(epoch), version \(version)")
        prepareEpoch(epoch, version)
        if epoch == 1 { sendKeyPackage() }
    }

    /// Opcode 25.
    func onExternalSender(_ bytes: Data) {
        session.setExternalSender(bytes)
        // The library makes the group (just this account in it) from the external sender. Only one key package goes to the server (after opcode 4): a second one made
        // the server add this account twice, and the library throws its first key package away once a commit is accepted.
        log("external sender set (\(bytes.count) bytes); protocol version \(session.protocolVersion); \(recognized.isEmpty ? "nobody else in the channel" : "\(recognized.count) other member(s)")")
        if recognized.isEmpty { onStatus?("alone in the channel; the encrypted group starts when someone joins") }
    }

    /// Opcode 27.
    func onProposals(_ bytes: Data) {
        let reply = session.processProposals(bytes, recognizedUserIDs: recognizedIDs)
        log("proposals (\(bytes.count) bytes) for \(recognizedIDs.count) member(s): \(reply == nil ? "no commit made" : "commit made")")
        if let reply { output?(.commitWelcome(reply)) }
    }

    /// Opcode 29.
    func onCommit(transitionID: Int, commit: Data) {
        let outcome = session.processCommit(commit)
        log("commit for transition \(transitionID) (\(commit.count) bytes): \(outcome)")
        switch outcome {
        case .ignored: return
        case .ok:
            joined = true
            prepareRatchets(transitionID, session.protocolVersion)
            readyIfNeeded(transitionID)
            onStatus?("encrypted")
        case .failed:
            output?(.invalidCommitWelcome(transitionID))
            handleInit(session.protocolVersion)
        }
    }

    /// Opcode 30.
    func onWelcome(transitionID: Int, welcome: Data) {
        if joined {
            // This account already made or joined the group (the library keeps no join key once that happens), so this welcome is not for it: do not report a failure.
            log("welcome for transition \(transitionID) (\(welcome.count) bytes) ignored: already in the encrypted group")
            return
        }
        let ok = session.processWelcome(welcome, recognizedUserIDs: recognizedIDs)
        log("welcome for transition \(transitionID) (\(welcome.count) bytes): \(ok ? "joined" : "not usable")")
        if ok {
            joined = true
            prepareRatchets(transitionID, session.protocolVersion)
            readyIfNeeded(transitionID)
            onStatus?("encrypted")
        } else {
            output?(.invalidCommitWelcome(transitionID))
            sendKeyPackage()
        }
    }

    // MARK: inside

    private func sendKeyPackage() { if let key = session.keyPackage() { output?(.keyPackage(key)) } }

    private func readyIfNeeded(_ id: Int) { if id != 0 { output?(.readyForTransition(id)) } }

    private func log(_ line: String) { Task { @MainActor in LogStore.shared.log("[discord-dave] \(line)") } }

    private func handleInit(_ version: UInt16) {
        if version > 0 {
            prepareEpoch(1, version)
            sendKeyPackage()
        } else {
            prepareRatchets(0, version)
            executeTransition(0)
        }
    }

    private func prepareEpoch(_ epoch: Int, _ version: UInt16) {
        // Epoch 1 is a brand new group (everyone else left, or the call was reset): this account is in no group until the commit or welcome of the new one arrives.
        // `joined` stayed true here in 9032, so the welcome that put this account into the new group was ignored ("already in the encrypted group") and the pictures
        // went on being encrypted with the old group's keys - which the viewer, who is in the new group, cannot open.
        if epoch == 1 { joined = false; session.start(version: version, channelID: groupID) }
    }

    private func executeTransition(_ id: Int) {
        guard let version = transitions[id] else { return }
        transitions[id] = nil
        if version == 0 { session.reset(); joined = false }
        setupRatchet(selfID, version: version)
    }

    private func setupRatchet(_ id: String, version: UInt16) {
        onRatchet?(id, version == 0 ? nil : session.keyRatchet(for: id), version)
    }

    private func prepareRatchets(_ id: Int, _ version: UInt16) {
        for user in recognizedIDs where user != selfID { setupRatchet(user, version: version) }
        if id == 0 { setupRatchet(selfID, version: version) } else { transitions[id] = version }
        latestPreparedVersion = version
    }
}
