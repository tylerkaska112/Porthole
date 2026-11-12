// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation
import Observation
import LauncherCore

/// Gets Microsoft's Visual C++ runtime onto the device: downloads Microsoft's installer, unpacks the 12 DLLs (see `VCRuntimeFiles`) and keeps them in
/// Application Support/Porthole/x86_64-vcruntime. The Windows side (WineProcessBridge) links them into each game's environment at start.
@MainActor @Observable
final class VCRuntimeInstaller {
    static let shared = VCRuntimeInstaller()

    enum State: Equatable { case idle, downloading(Double), unpacking, failed(String) }
    private(set) var state = State.idle
    private(set) var installed = VCRuntimeInstaller.hasDownloadedCopy

    /// Where the downloaded copy lives. The Windows side looks at exactly this path, so it must not follow the per-build storage folder name.
    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Porthole", isDirectory: true).appendingPathComponent("x86_64-vcruntime", isDirectory: true)
    }

    /// All 12 files are there at the right size. (They were verified byte for byte when they were put there.)
    nonisolated static var hasDownloadedCopy: Bool {
        VCRuntimeFiles.entries.allSatisfy { entry in
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(entry.name).path)[.size] as? Int) == entry.bytes
        }
    }

    /// A copy shipped inside this app (builds made on a machine that had the DLLs may carry them).
    nonisolated static var hasBundledCopy: Bool {
        Bundle.main.url(forResource: "x86_64-vcruntime", withExtension: nil).map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("vcruntime140.dll").path) } ?? false
    }

    /// Whether games will have the runtime: from the download, or from the app itself.
    var available: Bool { installed || Self.hasBundledCopy }
    var busy: Bool { switch state { case .downloading, .unpacking: true; default: false } }

    func install() async {
        guard !busy else { return }
        state = .downloading(0)
        do {
            var request = URLRequest(url: VCRuntimeFiles.installerURL)
            request.setValue("Porthole", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await ProgressTransport().download(request) { fraction in
                Task { @MainActor in if case .downloading = VCRuntimeInstaller.shared.state { VCRuntimeInstaller.shared.state = .downloading(fraction) } }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard response.statusCode == 200 else { throw VCRuntimeFiles.Failure.unreadable("Microsoft's server answered \(response.statusCode)") }
            state = .unpacking
            let target = Self.folder
            try await Task.detached(priority: .userInitiated) {
                let installer = try Data(contentsOf: file, options: .mappedIfSafe)
                let files = try VCRuntimeFiles.extract(installer: installer)
                // Written beside the final folder, then swapped in whole: the folder is either complete or not there.
                let fm = FileManager.default
                let staging = target.deletingLastPathComponent().appendingPathComponent("x86_64-vcruntime.new", isDirectory: true)
                try? fm.removeItem(at: staging)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for (name, data) in files { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: staging, to: target)
            }.value
            installed = Self.hasDownloadedCopy
            state = installed ? .idle : .failed("The files were not saved. Check that the device has free space.")
        } catch let error as VCRuntimeFiles.Failure {
            state = .failed(ErrorText.plain(error))
        } catch {
            state = .failed("Couldn't download it: \(ErrorText.plain(error))")
        }
    }

    /// Removes the downloaded copy (games then use Wine's own simpler version again).
    func remove() {
        try? FileManager.default.removeItem(at: Self.folder)
        installed = Self.hasDownloadedCopy
        state = .idle
    }
}
