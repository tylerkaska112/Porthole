// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CryptoKit
import Foundation
import Metal
import Observation
import LauncherCore

/// Windows programs that are not games but run in Porthole (Blender for now), offered for download from the Stores tab's Software section.
///
/// A small list (`software.json`, kept next to the programs' downloads) says what is on offer: its version, where the zip is, its SHA-256 and size, and the settings the program
/// is added to the library with. The app downloads the zip, checks the SHA-256, unpacks it into the Windows drive (`C:\Program Files\<folder>`) and adds it to the library.
/// When the list names a newer version than the one on the device, the Software page offers the update.
struct SoftwareItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var summary: String
    /// Any text; a different one from the installed copy's means there is an update.
    var version: String
    var url: URL
    var sha256: String
    var bytes: UInt64
    /// The program inside the unpacked folder, relative ("blender.exe").
    var exe: String
    /// The folder under `C:\Program Files` the zip is unpacked into.
    var folder: String
    /// What changed in this version, one or two lines.
    var notes: String?
    /// Library settings the program is added with (the person can change them afterwards in its page).
    var vramMB: Int?
    var swapMB: Int?
    var desktop: Bool?
    var symbol: String?
    /// Only for a device whose GPU has this architecture name (`applegpu_g16p`): what is built for one GPU generation (Blender's pre-built kernels) is offered to the devices that can use it.
    var arch: String?
    /// Only for a device running this system version ("27.2"): GPU binaries only fit the system version they were built for.
    var os: String?
    /// false = not a program to start: nothing is added to the library (a data pack that a program reads).
    var library: Bool?
    /// The id of the program this belongs to ("blender"): an add-on (Blender's GPU kernels) is not a card of its own in the Software list, it is offered on its program's page.
    var addonFor: String?
    /// What is known to be limited or wrong with the program, shown on its page (written in the list, so it changes without an app update).
    var known: [KnownIssue]?
}

/// One line of "Known limitations and problems" on a program's page.
struct KnownIssue: Codable, Equatable, Identifiable {
    /// "limitation" (how it is meant to be, or cannot be helped here) or "problem" (something wrong that is being looked at).
    var kind: String
    var title: String
    var detail: String
    /// When it was found or last checked ("build 17"), if worth saying.
    var found: String?
    var id: String { kind + "|" + title }
}

struct SoftwareManifest: Codable, Equatable {
    var software: [SoftwareItem]
}

/// What the device remembers about an installed program.
struct SoftwareInstalled: Codable, Equatable {
    var version: String
    var sha256: String
    var folder: String
    var exe: String
    var when: Date
}

@MainActor
final class SoftwareStore: ObservableObject {
    static let shared = SoftwareStore()

    /// Where the list is. (A file in the public repository of the Blender build; adding a program is a line there, not an app update.)
    nonisolated static let manifestURL = URL(string: "https://raw.githubusercontent.com/tylerkaska112/blender-porthole/main/software.json")!

    enum State: Equatable {
        case idle
        case downloading(Double)
        case verifying
        case unpacking(Double)
        case failed(String)
        var busy: Bool { switch self { case .downloading, .verifying, .unpacking: true; default: false } }
    }

    @Published private(set) var items: [SoftwareItem] = []
    @Published private(set) var installed: [String: SoftwareInstalled] = [:]
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var loading = false
    /// Set when the list could not be fetched (the last good copy is shown instead, if there is one).
    @Published private(set) var listError: String?

    private var tasks: [String: Task<Void, Never>] = [:]

    private nonisolated static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Porthole", isDirectory: true)
    }
    private nonisolated static var installedURL: URL { support.appendingPathComponent("software-installed.json") }
    private nonisolated static var listCacheURL: URL { support.appendingPathComponent("software-list.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.installedURL), let saved = try? JSONDecoder().decode([String: SoftwareInstalled].self, from: data) { installed = saved }
        if let data = try? Data(contentsOf: Self.listCacheURL), let list = try? JSONDecoder().decode(SoftwareManifest.self, from: data) { items = list.software.filter { Self.isUsable($0) && Self.fitsThisDevice($0) } }
    }

    // MARK: Questions

    func state(_ item: SoftwareItem) -> State { states[item.id] ?? .idle }
    func isInstalled(_ item: SoftwareItem) -> Bool { installed[item.id] != nil }
    func updateAvailable(_ item: SoftwareItem) -> Bool { installed[item.id].map { $0.version != item.version } ?? false }
    /// The library entry of an installed program.
    func game(for item: SoftwareItem) -> Game? { AppModel.shared.games.first { $0.softwareID == item.id } }
    /// How many programs have an update (for the badge on the Stores page).
    var updates: Int { items.filter(updateAvailable).count }

    /// This device's GPU architecture name (`applegpu_g16p` for an A17 Pro), or nil if it cannot be asked.
    nonisolated static var gpuArchitecture: String? {
        if #available(iOS 18.0, *) { return MTLCreateSystemDefaultDevice()?.architecture.name }
        return nil
    }
    /// The list entries this device can use.
    /// The system version as major.minor ("27.2"), the grain GPU binaries are built for.
    nonisolated static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
    private nonisolated static func fitsThisDevice(_ item: SoftwareItem) -> Bool {
        (item.arch == nil || item.arch == gpuArchitecture) && (item.os == nil || item.os == systemVersion)
    }

    /// The cards of the Software list: the programs (an add-on is offered on its program's page).
    var programs: [SoftwareItem] { items.filter { $0.addonFor == nil } }
    func item(_ id: String) -> SoftwareItem? { items.first { $0.id == id } }

    /// The add-ons of a program that fit this device, the one to recommend first: a pack built for exactly this GPU and system version, else one that works anywhere.
    func addons(of program: String) -> [SoftwareItem] {
        items.filter { $0.addonFor == program }.sorted { ($0.arch != nil ? 0 : 1) < ($1.arch != nil ? 0 : 1) }
    }
    /// The add-on installed now (they share a folder, so at most one is).
    func installedAddon(of program: String) -> SoftwareItem? { addons(of: program).first(where: isInstalled) }

    /// A list entry the app will act on: plain names only, an https address, a SHA-256 of the right length.
    nonisolated static func isUsable(_ item: SoftwareItem) -> Bool {
        func plain(_ s: String) -> Bool { !s.isEmpty && !s.contains("/") && !s.contains("\\") && !s.contains("..") && !s.hasPrefix(".") }
        return plain(item.id) && plain(item.folder) && !item.exe.contains("..") && !item.exe.isEmpty && item.url.scheme == "https" && item.sha256.count == 64
    }

    // MARK: The list

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Porthole", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let list = try JSONDecoder().decode(SoftwareManifest.self, from: data)
            items = list.software.filter { Self.isUsable($0) && Self.fitsThisDevice($0) }
            listError = nil
            try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            try? data.write(to: Self.listCacheURL, options: .atomic)
        } catch {
            listError = items.isEmpty ? "Couldn't load the list: \(ErrorText.plain(error))" : "Couldn't reach the list; showing the last one."
        }
    }

    // MARK: Install, update, remove

    func install(_ item: SoftwareItem) {
        guard !state(item).busy, Self.isUsable(item) else { return }
        guard !AppModel.shared.session.isActive || game(for: item) == nil else {
            states[item.id] = .failed("End the running program before updating it.")
            return
        }
        states[item.id] = .downloading(0)
        DownloadKeepAlive.shared.hold("software-\(item.id)")
        tasks[item.id] = Task { [weak self] in
            await self?.run(item)
            await MainActor.run {
                DownloadKeepAlive.shared.release("software-\(item.id)")
                self?.tasks[item.id] = nil
            }
        }
    }

    func cancel(_ item: SoftwareItem) {
        guard case .downloading = state(item) else { return }
        tasks[item.id]?.cancel()
    }

    func remove(_ item: SoftwareItem) {
        guard !state(item).busy else { return }
        if AppModel.shared.session.isActive, AppModel.shared.session.game?.softwareID == item.id { states[item.id] = .failed("End the running program first."); return }
        let folder = installed[item.id]?.folder ?? item.folder
        if Self.isUsable(item) || Self.plainName(folder) { try? FileManager.default.removeItem(at: Self.programFolder(folder)) }
        AppModel.shared.removeSoftware(id: item.id)
        installed.removeValue(forKey: item.id)
        states[item.id] = .idle
        saveInstalled()
    }

    private nonisolated static func plainName(_ s: String) -> Bool { !s.isEmpty && !s.contains("/") && !s.contains("\\") && !s.contains("..") && !s.hasPrefix(".") }
    private nonisolated static func programFolder(_ name: String) -> URL { AppModel.driveC.appendingPathComponent("Program Files", isDirectory: true).appendingPathComponent(name, isDirectory: true) }

    private func saveInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: Self.installedURL, options: .atomic) }
    }

    private func set(_ id: String, _ state: State) {
        // A step never goes backwards because a late progress callback arrived.
        if case .downloading = state, case .verifying = states[id] ?? .idle { return }
        states[id] = state
    }

    private func run(_ item: SoftwareItem) async {
        do {
            var request = URLRequest(url: item.url)
            request.setValue("Porthole", forHTTPHeaderField: "User-Agent")
            let id = item.id
            let (file, response) = try await ProgressTransport().download(request) { fraction in
                Task { @MainActor in SoftwareStore.shared.set(id, .downloading(fraction)) }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard response.statusCode == 200 else { throw SoftwareFailure.message("The download server answered \(response.statusCode).") }

            states[id] = .verifying
            let expected = item.sha256.lowercased()
            let actual = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: file) }.value
            guard actual == expected else { throw SoftwareFailure.message("The download is damaged or the list is out of date (checksum differs). Try again in a few minutes.") }

            states[id] = .unpacking(0)
            let folder = item.folder
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let parent = Self.programFolder(folder).deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let staging = parent.appendingPathComponent(folder + ".new", isDirectory: true)
                try? fm.removeItem(at: staging)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let total = max(1, try ItchZip.entries(of: file).reduce(UInt64(0)) { $0 + $1.size })
                try ItchZip.extract(file, to: staging, stripCommonFolder: false) { written in
                    Task { @MainActor in SoftwareStore.shared.set(id, .unpacking(min(1, Double(written) / Double(total)))) }
                }
                guard fm.fileExists(atPath: staging.appendingPathComponent(item.exe).path) else {
                    try? fm.removeItem(at: staging)
                    throw SoftwareFailure.message("The download does not contain \(item.exe).")
                }
                // Swapped in whole: the folder is either the old complete copy or the new complete copy.
                let target = Self.programFolder(folder)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: staging, to: target)
            }.value

            // What shares a folder replaces what was there (the GPU kernel packs): the others are no longer installed.
            for other in items where other.id != id && other.folder == item.folder { installed.removeValue(forKey: other.id) }
            installed[id] = SoftwareInstalled(version: item.version, sha256: expected, folder: item.folder, exe: item.exe, when: Date())
            saveInstalled()
            if item.library != false { AppModel.shared.upsertSoftware(item) }
            states[id] = .idle
        } catch is CancellationError {
            states[item.id] = .idle
        } catch let error as URLError where error.code == .cancelled {
            states[item.id] = .idle
        } catch let error as SoftwareFailure {
            states[item.id] = .failed(error.text)
        } catch let error as ItchZipError {
            states[item.id] = .failed(ErrorText.plain(error))
        } catch {
            states[item.id] = .failed("Couldn't install it: \(ErrorText.plain(error))")
        }
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum SoftwareFailure: Error {
    case message(String)
    var text: String { if case .message(let text) = self { return text }; return "" }
}
