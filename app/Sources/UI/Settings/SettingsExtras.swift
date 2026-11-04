// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import LauncherCore

// MARK: - Updates

struct UpdatesPage: View {
    @Environment(UpdateService.self) private var updates
    private enum Pick { case certificate, profile }
    @State private var picking: Pick?
    @State private var pendingP12: Data?
    @State private var password = ""
    @State private var askPassword = false
    @State private var viewing: Release?
    @State private var notesScope = FocusScope()
    @State private var showingSince = false
    @State private var sinceScope = FocusScope()
    @State private var versionPage = 0
    @State private var explaining = false
    @State private var downloadingBuild: String?
    @State private var downloadFraction = 0.0
    @State private var downloadError: String?
    @State private var downloaded: DownloadedFile?
    private struct DownloadedFile: Identifiable { let url: URL; var id: String { url.path } }

    /// Where every release is also published as a file. PLACEHOLDER until the project's real GitHub address is settled.
    private static let releasesURL = URL(string: "https://github.com/tylerkaska112/PortHole/releases")!
    private static let perPage = 5

    var body: some View {
        PageScaffold(title: "Updates", symbol: "arrow.triangle.2.circlepath", subtitle: "Keep Porthole up to date") {
            SettingsGroup(title: "This app", note: "The version you are on and whether a newer one is ready.") {
                ValueRow(id: "up-version", symbol: "app.badge.fill", title: "Installed", value: "\(updates.version) (\(updates.build))")
                statusRow
                ActionRow(id: "up-check", symbol: "arrow.clockwise", title: "Check for updates", chevron: false) { Task { await updates.check() } }
                if let release = updates.available {
                    if updates.vault.canSign {
                        ActionRow(id: "up-install", symbol: "arrow.down.circle.fill", title: "Update to \(release.title)", subtitle: release.summary.isEmpty ? nil : release.summary, chevron: false) {
                            if !updates.pipeline.isBusy { updates.startUpdate(release) }
                        }
                    } else {
                        ActionRow(id: "up-install", symbol: "arrow.down.circle.fill", title: "Download \(release.title)", subtitle: release.summary.isEmpty ? "The file, to install yourself" : release.summary,
                                  detail: downloadingBuild == release.build ? "\(Int(downloadFraction * 100))%" : nil, chevron: false) { download(release) }
                    }
                }
                if downloadingBuild != nil, !updates.vault.canSign { progressRow("Downloading", downloadFraction) }
                if let downloadError { Text(downloadError).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
                jobRows
            }
            allVersions
            SettingsGroup(title: "Signing", note: "The certificate and profile used to install and update. A free Apple account's signature lasts seven days.") {
                ForEach(updates.vault.certificates) { c in
                    ActionRow(id: "up-cert-\(c.id)", symbol: "person.text.rectangle.fill", title: c.label, subtitle: "Certificate", detail: "Remove", destructive: true, chevron: false) { updates.vault.removeCertificate(id: c.id) }
                }
                ForEach(updates.vault.profiles) { p in
                    ActionRow(id: "up-prof-\(p.id)", symbol: "doc.badge.gearshape.fill", title: p.profile.name, subtitle: profileDetail(p.profile), detail: "Remove", destructive: true, chevron: false) { updates.vault.removeProfile(id: p.id) }
                }
                ForEach(updates.vault.problems(), id: \.id) { problem in
                    Text("\(problem.subject): \(problem.message)").font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6)
                }
                ActionRow(id: "up-explain", symbol: "questionmark.circle.fill", title: "What is this?", subtitle: "Why the app needs a certificate and a profile to update itself", chevron: false) { explaining = true }
                ActionRow(id: "up-import-cert", symbol: "square.and.arrow.down", title: "Import a certificate (.p12)") { picking = .certificate }
                ActionRow(id: "up-import-prof", symbol: "square.and.arrow.down", title: "Import a profile (.mobileprovision)") { picking = .profile }
                if let message = updates.message { Text(message).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 6) }
            }
        }
        .task { await updates.check() }
        .sheet(isPresented: $explaining) { SigningExplainerView() }
        .sheet(item: $downloaded) { ActivityView(items: [$0.url]) }
        .sheet(item: Binding(get: { picking.map(PickWrapper.init) }, set: { picking = $0?.pick })) { wrapper in
            FilePickerSheet(onPick: { urls in handle(urls.first, as: wrapper.pick); picking = nil }, onCancel: { picking = nil })
        }
        .sheet(isPresented: $showingSince) {
            let installedBuild = Int(updates.build) ?? 0
            let newer = (updates.status?.releases ?? []).filter { $0.buildNumber > installedBuild }.sorted { $0.buildNumber > $1.buildNumber }
            SinceYourVersionSheet(installed: "\(updates.version) (\(updates.build))", releases: newer, canSign: updates.vault.canSign, busy: updates.pipeline.isBusy, scope: sinceScope,
                                  install: {
                                      showingSince = false
                                      guard let latest = newer.first else { return }
                                      if updates.vault.canSign { if !updates.pipeline.isBusy { updates.startUpdate(latest) } } else { download(latest) }
                                  },
                                  close: { showingSince = false })
        }
        .sheet(item: $viewing) { release in
            ReleaseNotesSheet(release: release, isInstalled: isInstalled(release), isOlder: isOlder(release), canSign: updates.vault.canSign, busy: updates.pipeline.isBusy, scope: notesScope,
                              install: {
                                  viewing = nil
                                  if updates.vault.canSign { if !updates.pipeline.isBusy { updates.startUpdate(release) } } else { download(release) }
                              },
                              close: { viewing = nil })
        }
        .alert("Certificate password", isPresented: $askPassword) {
            SecureField("Password", text: $password)
            Button("Import") { importCertificate() }
            Button("Cancel", role: .cancel) { pendingP12 = nil; password = "" }
        } message: { Text("The password you set when you exported the .p12.") }
    }

    private struct PickWrapper: Identifiable { let pick: Pick; var id: Int { pick == .certificate ? 0 : 1 } }

    /// Without a certificate there is nothing to sign with: fetch the file as the server has it and hand it to the share sheet (Save to Files, AirDrop, another app).
    private func download(_ release: Release) {
        guard downloadingBuild == nil, let app = updates.app, let client = updates.catalog.client(for: app) else { return }
        downloadingBuild = release.build; downloadFraction = 0; downloadError = nil
        Task {
            do {
                let url = try await client.download(release, to: FileStorage.cacheURL("Downloads")) { fraction in Task { @MainActor in downloadFraction = fraction } }
                downloaded = DownloadedFile(url: url)
            } catch { downloadError = error.localizedDescription }
            downloadingBuild = nil
        }
    }

    private func isInstalled(_ release: Release) -> Bool { release.version == updates.version && release.build == updates.build }
    private func isOlder(_ release: Release) -> Bool { release.buildNumber < (Int(updates.build) ?? 0) }

    /// Five versions at a time, newest first: the whole history (hundreds of builds) made the page slow to open and slow to scroll.
    @ViewBuilder private var allVersions: some View {
        if let releases = updates.status?.releases, !releases.isEmpty {
            let pages = (releases.count + Self.perPage - 1) / Self.perPage
            let page = min(max(versionPage, 0), pages - 1)
            let shown = Array(releases[(page * Self.perPage)..<min((page + 1) * Self.perPage, releases.count)])
            SettingsGroup(title: "Versions", note: "Every build on the update server, so you can go back to an older one.") {
                ForEach(shown) { release in
                    ActionRow(id: "up-v-\(release.build)", symbol: isInstalled(release) ? "checkmark.circle.fill" : "clock.arrow.circlepath", tint: isInstalled(release) ? Theme.good : Theme.accent,
                              title: release.title, subtitle: release.summary.isEmpty ? nil : release.summary,
                              detail: isInstalled(release) ? "Installed" : (downloadingBuild == release.build ? "\(Int(downloadFraction * 100))%" : nil)) {
                        viewing = release
                    }
                }
                if pages > 1 {
                    HStack(spacing: 10) {
                        PillButton(id: "up-newer", title: "Newer", symbol: "chevron.left", enabled: page > 0) { versionPage = page - 1 }
                        Text("\(page * Self.perPage + 1)\u{2013}\(min((page + 1) * Self.perPage, releases.count)) of \(releases.count)")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity)
                        PillButton(id: "up-older", title: "Older", symbol: "chevron.right", enabled: page < pages - 1) { versionPage = page + 1 }
                    }
                }
                Text(updates.vault.canSign
                     ? "Tap a version to read what it added, changed and fixed, and to install it. Older versions are for when something stopped working."
                     : "Tap a version to read what it added, changed and fixed, and to download the file to install with your own tool. Older versions are for when something stopped working.")
                    .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                if !updates.vault.canSign {
                    Text("Every release is also published on GitHub, where you can download the files too.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                    ActionRow(id: "up-github", symbol: "arrow.up.right.square", title: "Open the releases on GitHub", chevron: false) { UIApplication.shared.open(Self.releasesURL) }
                }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updates.status?.phase {
        case .loading?: ValueRow(id: "up-status", symbol: "hourglass", title: "Status", value: "Checking\u{2026}")
        case .failed(let why)?:
            if NetworkStatus.shared.isOnline { ValueRow(id: "up-status", symbol: "exclamationmark.triangle.fill", title: "Status", value: why, statusColor: Theme.bad) }
            else { ValueRow(id: "up-status", symbol: "wifi.slash", title: "Status", value: "Offline: it checks again when there is a connection", statusColor: Theme.warn) }
        case .loaded?:
            if let release = updates.available {
                // Tapping it lists everything added, changed and fixed since the version you have.
                ActionRow(id: "up-status", symbol: "sparkles", tint: Theme.good, title: "Update available", subtitle: "\(release.title). Tap to see everything since \(updates.version) (\(updates.build)).", chevron: true) { showingSince = true }
            }
            else { ValueRow(id: "up-status", symbol: "checkmark.circle.fill", title: "Status", value: "Up to date", statusColor: Theme.good) }
        default: ValueRow(id: "up-status", symbol: "questionmark.circle", title: "Status", value: "Not checked yet")
        }
        if !updates.vault.canSign { Text("No certificate added, so new versions are downloaded as files. Add a certificate and a profile below to let the app update itself.").font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6) }
    }

    @ViewBuilder private var jobRows: some View {
        if let job = updates.pipeline.job {
            switch job.phase {
            case .downloading(let p): progressRow("Downloading", p)
            case .signing(let step): ValueRow(id: "up-job", symbol: "signature", title: "Signing", value: step)
            case .installing(let stage, let p): progressRow(stage, p)
            case .installed: ValueRow(id: "up-job", symbol: "checkmark.circle.fill", title: job.title, value: "Installed. The app restarts.", statusColor: Theme.good)
            case .saved(let file):
                ValueRow(id: "up-job", symbol: "checkmark.circle.fill", title: job.title, value: "Signed, not installed")
                ShareLink(item: file) { Label("Save or share the signed file", systemImage: "square.and.arrow.up") }
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .failed(let why): ValueRow(id: "up-job", symbol: "xmark.octagon.fill", title: job.title, value: why, statusColor: Theme.bad)
            }
            ForEach(job.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 6) }
            if job.isFinished { ActionRow(id: "up-job-dismiss", symbol: "xmark", title: "Dismiss", chevron: false) { updates.pipeline.dismiss() } }
        }
    }

    private func progressRow(_ title: String, _ fraction: Double) -> some View {
        VStack(spacing: 6) {
            HStack { Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text); Spacer(); Text("\(Int((fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(Theme.textDim) }
            if fraction > 0 { ProgressView(value: fraction).tint(Theme.accent) } else { ProgressView().tint(Theme.accent) }
        }
        .padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func profileDetail(_ profile: ProvisioningProfile) -> String {
        var text = profile.applicationIdentifier
        if let expiry = profile.expiration { text += "  expires " + expiry.formatted(date: .abbreviated, time: .omitted) }
        return text
    }

    private func handle(_ url: URL?, as kind: Pick) {
        guard let url, let data = try? Data(contentsOf: url) else { updates.message = "Could not read that file."; return }
        SecretFiles.discard(url)          // the picker's copy; what matters is kept in the Keychain
        updates.message = nil
        switch kind {
        case .certificate:
            guard url.hasExtension("p12", "pfx") else { updates.message = "That is not a .p12 file."; return }
            pendingP12 = data; password = ""; askPassword = true
        case .profile:
            guard url.hasExtension("mobileprovision") else { updates.message = "That is not a .mobileprovision file."; return }
            do { _ = try updates.vault.importProfile(data) } catch { updates.message = error.localizedDescription }
        }
    }

    private func importCertificate() {
        guard let data = pendingP12 else { return }
        do { _ = try updates.vault.importCertificate(data, password: password) } catch { updates.message = error.localizedDescription }
        pendingP12 = nil; password = ""
    }
}

// MARK: - Compatibility reports

struct ReportsSettingsPage: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var compat = CompatStore.shared
    @AppStorage(CompatStore.showBadgesKey) private var showBadges = true
    @AppStorage(CompatStore.askKey) private var ask = true
    @State private var confirmReset = false

    var body: some View {
        PageScaffold(title: "Compatibility reports", symbol: "checkmark.seal.fill", subtitle: "How reports and badges work for you") {
            SettingsGroup(title: "Reports tab", note: "How your games run on this version of the engine, what other people reported, and the reports you sent.") {
                ActionRow(id: "rp-open", symbol: "checkmark.seal.fill", title: "Open the Reports tab", subtitle: "Your games and everything people reported") { router.openReports(.mine) }
                ActionRow(id: "rp-mine", symbol: "paperplane.fill", title: "My reports",
                          subtitle: compat.queuedCount > 0 ? "\(compat.queuedCount) waiting to be sent" : "The reports you sent, and how to delete one") { router.openReports(.sent) }
            }
            SettingsGroup(title: "Badges", note: "Small marks on games that show how they ran for other people.") {
                ToggleRow(id: "rp-badges", symbol: "checkmark.seal.fill", title: "Show compatibility badges",
                          info: "Badges come from reports other people sent. After a game you can send one yourself; it takes under a minute.", isOn: $showBadges)
                ToggleRow(id: "rp-ask", symbol: "questionmark.bubble.fill", title: "Ask me how a game ran", isOn: $ask)
            }
            SettingsGroup(title: "Privacy", note: "Reports carry a random key kept on this device, not your name, and the game's log, which only the developer can read.") {
                ActionRow(id: "rp-forget", symbol: "person.fill.xmark", title: "Forget my reporting identity",
                          info: "Reports are tied to a random key kept on this device, not to you. Forgetting it starts fresh: your old reports stay up but you can no longer edit or delete them.", destructive: true, chevron: false) { confirmReset = true }
            }
        }
        .confirm("Forget this device's reporting identity?", confirmTitle: "Forget", destructive: true, isPresented: $confirmReset) { compat.forgetLocalData() }
    }
}

// MARK: - Log

struct LogPage: View {
    @ObservedObject private var store = LogStore.shared
    @State private var reading = false
    @State private var scope = FocusScope()

    private var text: String {
        let lines = store.entries.suffix(400).reversed().map { "\($0.level.rawValue) \($0.lastRaw)\($0.count > 1 ? "  x\($0.count)" : "")" }
        return stride(from: 0, to: lines.count, by: 14).map { lines[$0..<min($0 + 14, lines.count)].joined(separator: "\n") }.joined(separator: "\n\n")
    }

    var body: some View {
        PageScaffold(title: "Log", symbol: "doc.text.fill") {
            SettingsGroup(title: "Log", note: "What Porthole and the engine wrote during the last run. Report a problem sends it for you.") {
                ValueRow(id: "lg-count", symbol: "list.bullet", title: "Entries", value: "\(store.entries.count)")
                ActionRow(id: "lg-read", symbol: "doc.text.magnifyingglass", title: "Read the log", subtitle: "Newest first. Share it from the Files app: Porthole > madeira-log.txt") { reading = true }
            }
        }
        .sheet(isPresented: $reading) { TextReaderSheet(title: "Log", text: text, monospaced: true, scope: scope) { reading = false } }
    }
}

// MARK: - Licences

struct LicencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope = FocusScope()
    @State private var readerScope = FocusScope()
    @State private var reading: LegalDocument?
    @State private var showTexts = false

    var body: some View {
        ZStack {
            AmbientBackdrop(animated: false)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Licences and source code").font(.system(size: 24, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    PillButton(id: "lic-close", title: "Close", symbol: "xmark") { dismiss() }
                }
                FocusScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsGroup(title: "Porthole") {
                            Text("Porthole is free software. You may use, study, change and share it under the terms of the GNU General Public License, version 3 or later. There is no warranty.")
                                .font(.footnote).foregroundStyle(Theme.textDim).padding(.horizontal, 6)
                            ForEach(LegalLibrary.porthole) { doc($0) }
                            if let source = BuildIdentity.sourceURL { ActionRow(id: "lic-src", symbol: "arrow.up.right.square", title: "Source code online", subtitle: source.absoluteString, chevron: false) { UIApplication.shared.open(source) } }
                            if let site = URL(string: "https://portholehq.site") { ActionRow(id: "lic-site", symbol: "globe", title: "Project website", subtitle: "portholehq.site", chevron: false) { UIApplication.shared.open(site) } }
                        }
                        SettingsGroup(title: "Built on") {
                            ForEach(LegalLibrary.credits) { doc($0) }
                            ActionRow(id: "lic-texts", symbol: "doc.on.doc.fill", title: "Licence texts", subtitle: "The licences of the parts it is built from") { showTexts.toggle() }
                            if showTexts { ForEach(LegalLibrary.licenceTexts) { doc($0, id: "lt-") } }
                        }
                        SettingsGroup(title: "Apple") { ForEach(LegalLibrary.apple) { doc($0) } }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
        .navScope(scope)
        .onAppear { scope.onBack = { dismiss() }; scope.defaultFocus = "lic-close"; scope.focused = "lic-close" }
        .presentationBackground(Theme.background)
        .preferredColorScheme(Theme.scheme)
        .sheet(item: $reading) { document in
            TextReaderSheet(title: document.title, text: document.text.map { document.keepsLayout ? $0 : LegalDocument.reflowed($0) } ?? "This document is not in the app.",
                            monospaced: document.keepsLayout, scope: readerScope) { reading = nil }
        }
    }

    @ViewBuilder private func doc(_ d: LegalDocument, id prefix: String = "") -> some View {
        if d.url != nil { ActionRow(id: "lic-\(prefix)\(d.id)", symbol: "doc.plaintext", title: d.title, subtitle: d.detail) { reading = d } }
    }
}
