// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import LauncherCore

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func _copyEntitlement(_ task: SecTaskRef, _ entitlement: NSString, _ error: NSErrorPointer) -> Unmanaged<CFTypeRef>?

@_silgen_name("SecTaskCreateFromSelf")
private func _taskFromSelf(_ allocator: CFAllocator?) -> SecTaskRef?

/// What this install is made of and what it was signed with.
///
/// Porthole can be installed in three ways to spend fewer App IDs (a free Apple account has very few): with both helper extensions, without the private-link
/// tunnel (LocalDevVPN provides it), or with neither (StikDebug or another tool switches JIT on). The person (or the Launcher, when they update through it)
/// removes the extensions while signing. This looks at what is actually inside the app and which permissions the signature really carries, so the app can
/// explain in plain words what works, instead of failing later with a vague error.
enum InstallCheck {
    static let helperName = "F4JITHelper.appex"
    static let tunnelName = "F4Tunnel.appex"
    static let activityName = "F4Activity.appex"
    static let memoryHostName = "F4MemoryHost.appex"

    // MARK: Which extensions are inside

    private static func extensionURL(_ name: String) -> URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent(name)
    }

    private static func exists(_ name: String) -> Bool {
        guard let url = extensionURL(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The JIT helper extension (switches JIT on from inside the app).
    static var hasJITHelper: Bool { exists(helperName) }
    /// The packet-tunnel extension (Porthole's own private link).
    static var hasTunnel: Bool { exists(tunnelName) }

    /// The Live Activity extension (the download card with its Pause and Cancel buttons on the lock screen).
    static var hasActivityExtension: Bool { exists(activityName) }

    /// The donor-RAM extension (extra memory for a game that needs more than the app's own limit; Settings > Engine options > Donor memory).
    static var hasMemoryHost: Bool { exists(memoryHostName) }

    enum DonorMemory: Equatable {
        case ready
        /// Left out of this install (signed without it to save an App ID).
        case missing
        /// Inside the app but iOS will not run it: no signature of its own, or the profile ran out.
        case unusable(String)
    }

    /// Whether Settings > Engine options > Donor memory can work in this install: the extension is inside, carries its own profile and iOS knows it by its bundle id.
    static var donorMemory: DonorMemory {
        guard hasMemoryHost else { return .missing }
        guard let bundle = extensionBundle(memoryHostName) else { return .unusable("its folder cannot be read") }
        guard let ext = profile(in: bundle) else { return .unusable("it was not signed with a profile of its own") }
        if ext.isExpired { return .unusable("its profile has expired") }
        if bundle.bundleIdentifier != (Bundle.main.bundleIdentifier ?? "") + ".MemoryHost" { return .unusable("its bundle id does not match the app's") }
        return .ready
    }

    /// One line for the Donor memory row.
    static var donorMemoryNote: String {
        switch donorMemory {
        case .ready: "Memory Host extension found: ready."
        case .missing: "No Memory Host extension in this install: this does nothing here."
        case .unusable(let why): "Memory Host extension found, but iOS will not run it (\(why))."
        }
    }

    /// Extensions that were left out of this install: an update has to be signed the same way, so they are not put back.
    static var missingExtensions: [String] {
        [(helperName, hasJITHelper), (tunnelName, hasTunnel), (activityName, hasActivityExtension), (memoryHostName, hasMemoryHost)].filter { !$0.1 }.map(\.0)
    }

    /// How many App IDs this install uses: the app, plus one for each extension inside.
    static var appIDCount: Int { 1 + (hasJITHelper ? 1 : 0) + (hasTunnel ? 1 : 0) + (hasActivityExtension ? 1 : 0) + (hasMemoryHost ? 1 : 0) }

    enum Layout { case full, noTunnel, noHelper, minimal }

    static var layout: Layout {
        switch (hasJITHelper, hasTunnel) {
        case (true, true): .full
        case (true, false): .noTunnel
        case (false, true): .noHelper
        case (false, false): .minimal
        }
    }

    static var layoutTitle: String {
        switch layout {
        case .full: "Complete install"
        case .noTunnel: "Without the private link"
        case .noHelper: "Without the JIT helper"
        case .minimal: "Lightest install"
        }
    }

    private static var idsText: String {
        " Uses \(appIDCount) App ID\(appIDCount == 1 ? "" : "s")" + (hasActivityExtension ? ", one of them for the download card on the lock screen." : ".")
    }

    static var layoutSummary: String {
        switch layout {
        case .full: "Porthole turns JIT on by itself and brings its own private link." + idsText
        case .noTunnel: "Porthole turns JIT on by itself, using LocalDevVPN for the private link." + idsText
        case .noHelper: "JIT is switched on with StikDebug or another tool; Porthole brings its own private link." + idsText
        case .minimal: "JIT is switched on with StikDebug or another tool, and LocalDevVPN is the private link if the tool needs one." + idsText
        }
    }

    // MARK: What the signature carries

    private static func entitlement(_ key: String) -> Any? {
        guard let task = _taskFromSelf(nil), let value = _copyEntitlement(task, key as NSString, nil)?.takeRetainedValue() else { return nil }
        return value
    }

    private static func has(_ key: String) -> Bool { (entitlement(key) as? NSNumber)?.boolValue ?? false }

    private static func strings(_ key: String) -> [String] { entitlement(key) as? [String] ?? [] }

    private static func profile(in bundle: Bundle) -> ProvisioningProfile? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? ProvisioningProfile(data: data)
    }

    private static func extensionBundle(_ name: String) -> Bundle? { extensionURL(name).flatMap { Bundle(url: $0) } }

    private static func hasPacketTunnel(_ values: [String]) -> Bool { values.contains { $0.hasPrefix("packet-tunnel-provider") } }

    // MARK: Findings

    enum Level: Int, Comparable {
        case good, info, warning, problem
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Finding: Identifiable, Equatable {
        let id: String
        let level: Level
        let title: String
        let detail: String
    }

    /// Everything worth telling the person about this install, worst first. Cheap enough to call from a view body.
    static func findings() -> [Finding] {
        var out: [Finding] = []
        let appProfile = profile(in: .main)

        // JIT needs a debugger to be allowed to attach: get-task-allow, which a distribution or enterprise signature does not carry.
        let signing = SigningStatus.current
        if !signing.debuggable {
            out.append(.init(id: "task-allow", level: .problem, title: "JIT cannot be switched on",
                             detail: "This copy was signed without the \u{201C}debuggable\u{201D} permission (get-task-allow), which comes with a distribution or enterprise certificate. No tool can turn JIT on for it. Sign it with a development certificate and profile."))
        } else {
            out.append(.init(id: "task-allow", level: .good, title: "JIT can be switched on", detail: "This copy is signed so a debugger may attach."))
        }

        let sharedFix = appProfile.map { $0.grants("com.apple.developer.kernel.increased-memory-limit") } == true
            ? "Your profile has it, but the tool that signed this app left it out. Turn on its \u{201C}keep entitlements\u{201D} option, or sign with the Launcher."
            : "Your profile does not include it. A paid Apple Developer account can add the \u{201C}Increased Memory Limit\u{201D} capability to the App ID; a free account cannot."
        if has("com.apple.developer.kernel.increased-memory-limit") {
            out.append(.init(id: "memory", level: .good, title: "Extra memory allowed", detail: "Games may use more memory than a normal app."))
        } else {
            out.append(.init(id: "memory", level: .warning, title: "Extra memory is not allowed",
                             detail: "Big games may close on their own without warning. " + sharedFix))
        }

        let vaFix = appProfile.map { $0.grants("com.apple.developer.kernel.extended-virtual-addressing") } == true
            ? "Your profile has it, but the tool that signed this app left it out."
            : "Your profile does not include \u{201C}Extended Virtual Addressing\u{201D}; a paid Apple Developer account can add it to the App ID."
        if has("com.apple.developer.kernel.extended-virtual-addressing") {
            out.append(.init(id: "address-space", level: .good, title: "Large address space allowed", detail: "Games can map the memory the engine reserves for them."))
        } else {
            out.append(.init(id: "address-space", level: .warning, title: "Large address space is not allowed",
                             detail: "Some games will not start, or close shortly after they do. " + vaFix))
        }

        // The private link: the app creates the VPN configuration (needs the Network Extensions permission itself) and its extension runs it.
        if hasTunnel {
            let appOK = hasPacketTunnel(strings("com.apple.developer.networking.networkextension"))
            let ext = extensionBundle(tunnelName).flatMap { profile(in: $0) }
            let extOK = ext.map { hasPacketTunnel($0.stringValues("com.apple.developer.networking.networkextension")) } ?? false
            if !appOK || !extOK {
                let who = !appOK && !extOK ? "the app and its tunnel extension" : (!appOK ? "the app" : "its tunnel extension")
                out.append(.init(id: "tunnel", level: UserDefaults.standard.bool(forKey: "f4.useLocalDevVPN") ? .info : .problem, title: "The private link cannot start",
                                 detail: "\(who.prefix(1).uppercased() + who.dropFirst()) was signed without the \u{201C}Network Extensions\u{201D} permission, so iOS will not run Porthole's own tunnel. Turn on \u{201C}Use LocalDevVPN instead\u{201D} and run LocalDevVPN, or install again without the tunnel extension to save an App ID."))
            } else if let ext, let appProfile, ext.teamID != appProfile.teamID {
                out.append(.init(id: "tunnel", level: .problem, title: "The private link was signed by another team",
                                 detail: "The tunnel extension and the app were signed with different profiles, so iOS will not start it. Sign both with the same certificate and team."))
            } else {
                out.append(.init(id: "tunnel", level: .good, title: "The private link can start", detail: "The tunnel extension carries the Network Extensions permission."))
            }
        } else if layout == .noTunnel || layout == .minimal {
            out.append(.init(id: "tunnel-absent", level: .info, title: "No private link inside this install",
                             detail: "Run LocalDevVPN when a tool needs the private link to switch JIT on. Porthole does not start its own VPN, so your own VPN is left alone."))
        }

        if hasJITHelper {
            let ext = extensionBundle(helperName).flatMap { profile(in: $0) }
            if ext == nil {
                out.append(.init(id: "helper", level: .problem, title: "The JIT helper has no signature",
                                 detail: "iOS will not run the JIT helper. Install again so both the app and the helper are signed."))
            } else if ext?.isExpired == true {
                out.append(.init(id: "helper", level: .problem, title: "The JIT helper's profile has expired", detail: "Sign Porthole again to renew it."))
            }
        } else {
            out.append(.init(id: "helper-absent", level: .info, title: "No JIT helper inside this install",
                             detail: "Switch JIT on with StikDebug or another tool. \u{201C}Porthole does it\u{201D} is not available in this install."))
        }

        if !hasActivityExtension {
            out.append(.init(id: "activity-absent", level: .info, title: "No download card extension inside this install",
                             detail: "Downloads show iOS's own download card (percentage, size and speed) instead of the one with Pause and Cancel buttons. It saves an App ID."))
        }

        switch donorMemory {
        case .ready:
            out.append(.init(id: "memoryhost", level: .good, title: "Donor memory can start", detail: "The Memory Host extension is inside and signed."))
        case .missing:
            out.append(.init(id: "memoryhost-absent", level: .info, title: "No donor memory extension inside this install",
                             detail: "Settings > Advanced > Engine options > Memory > Donor memory does nothing in this install. It saves an App ID."))
        case .unusable(let why):
            out.append(.init(id: "memoryhost", level: .warning, title: "Donor memory cannot start",
                             detail: "The Memory Host extension is inside, but \(why), so iOS will not run it. Sign Porthole again, or install without it to save an App ID."))
        }

        // A free account's profile lasts seven days.
        if let end = appProfile?.expiration {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0
            if end < Date() {
                out.append(.init(id: "expiry", level: .problem, title: "The signature has expired", detail: "Sign Porthole again to keep opening it."))
            } else if days <= 2 {
                out.append(.init(id: "expiry", level: .warning, title: days == 0 ? "The signature expires today" : "The signature expires in \(days) day\(days == 1 ? "" : "s")",
                                 detail: "Sign Porthole again before then so it keeps opening. Updating through the Launcher does this."))
            }
        }

        return out.sorted { $0.level > $1.level }
    }

    /// What deserves a notice on Home: things that stop games from starting or from running well.
    static var attention: [Finding] { findings().filter { $0.level >= .warning } }

    /// A stable key for the Home notice, so a dismissal holds until the signature changes.
    static func noticeKey(_ items: [Finding]) -> String { "install:" + items.map(\.id).sorted().joined(separator: ",") }

    /// One log line per fact, written at start so a bug report shows how the app was installed and signed.
    static func logReport() {
        LogStore.shared.log("[install] \(layoutTitle): JIT helper \(hasJITHelper ? "yes" : "no"), tunnel \(hasTunnel ? "yes" : "no"), download card \(hasActivityExtension ? "yes" : "no"), donor memory \(hasMemoryHost ? "yes" : "no")")
        for f in findings() where f.level != .info {
            let level: LogStore.LogEntry.Level = f.level == .problem ? .error : (f.level == .good ? .success : .info)
            LogStore.shared.log("[install] \(f.level == .good ? "ok" : f.level == .problem ? "PROBLEM" : "note"): \(f.title)", level: level)
        }
    }
}
