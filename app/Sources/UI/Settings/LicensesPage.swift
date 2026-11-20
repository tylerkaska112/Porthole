// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import SwiftUI
import LauncherCore

/// A licence, notice or credit text that ships inside the app, so the licences are always with the copy that needs them.
struct LegalDocument: Identifiable, Hashable {
    let title: String
    let detail: String?
    /// File name inside the app bundle, and the folder it is in (`nil` = the top level).
    let file: String
    var folder: String? = nil
    var id: String { (folder.map { $0 + "/" } ?? "") + file }

    var url: URL? {
        let name = file as NSString
        let base = name.deletingPathExtension, ext = name.pathExtension
        // A name like "LICENSE" has no extension; one like "LICENSE-EXCEPTION.md" does.
        return Bundle.main.url(forResource: ext.isEmpty ? file : base, withExtension: ext.isEmpty ? nil : ext, subdirectory: folder)
    }
    var text: String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
    /// Markdown files (tables, code) keep their layout; plain licence texts are hard-wrapped at 80 columns and are joined into paragraphs.
    var keepsLayout: Bool { file.hasSuffix(".md") }

    /// Joins the lines of each paragraph so the text flows to the width of the screen. A paragraph with indented or column-aligned lines is left as it is.
    static func reflowed(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").map { paragraph -> String in
            let lines = paragraph.components(separatedBy: "\n")
            guard lines.count > 1 else { return paragraph.trimmingCharacters(in: .whitespaces) }
            let indented = lines.dropFirst().contains { line in line.prefix(while: { $0 == " " }).count >= 4 }
            if indented { return paragraph }
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}

enum LegalLibrary {
    static let porthole: [LegalDocument] = [
        LegalDocument(title: "Licence", detail: "GNU General Public License, version 3 or later", file: "LICENSE"),
        LegalDocument(title: "Additional permission", detail: "For Apple's Metal Shader Converter", file: "LICENSE-EXCEPTION.md"),
        LegalDocument(title: "Source code and how to rebuild", detail: "Where the source is, and the exact versions used", file: "SOURCE.md"),
    ]
    static let credits: [LegalDocument] = [
        LegalDocument(title: "Credits", detail: "Who made what this app is built on", file: "CREDITS.md"),
        LegalDocument(title: "Third-party components", detail: "Wine, FEX, DXMT, FFmpeg and the rest", file: "THIRD-PARTY-NOTICES.md", folder: "legal"),
        LegalDocument(title: "3D model of the DualSense", detail: "\"Playstation 5 Dualsense\" by AHarmlessPotato, CC BY 4.0", file: "DualSense-LICENSE.txt", folder: "Models"),
        LegalDocument(title: "3D model of the DualShock 4", detail: "\"DualShock 4 PlayStation Controller\" by shaielwolf, CC BY 4.0", file: "DualShock4-LICENSE.txt", folder: "Models"),
        LegalDocument(title: "3D model of the Xbox controller", detail: "\"Xbox Controller\" by umkhero, CC BY 4.0", file: "Xbox-LICENSE.txt", folder: "Models"),
        LegalDocument(title: "StikJIT, idevice and StikDebug", detail: "JIT support: what is included and where its source is", file: "StikJIT.md"),
        LegalDocument(title: "MPL-2.0 (StikJIT)", detail: "The licence of the JIT library", file: "MPL-2.0-StikJIT.txt"),
        LegalDocument(title: "Libraries inside StikJIT", detail: "About 130 Rust libraries and their licences", file: "StikJIT-rust-libraries.txt"),
        LegalDocument(title: "Libraries behind the Discord features", detail: "libdave, mlspp, OpenSSL, libdatachannel, Opus and the rest: what each does and where its source is", file: "Discord-libraries.md"),
        LegalDocument(title: "Licences of the Discord libraries", detail: "MIT, BSD, Apache-2.0 and MPL-2.0 texts", file: "Discord-libraries-licences.txt"),
    ]
    static let apple: [LegalDocument] = [
        LegalDocument(title: "Metal Shader Converter agreement", detail: "Apple's terms for the converter library", file: "METAL-SHADER-CONVERTER-AGREEMENT.txt", folder: "d3d12"),
        LegalDocument(title: "Metal Shader Converter notice", detail: nil, file: "NOTICE.txt", folder: "d3d12"),
        LegalDocument(title: "Metal Shader Converter headers licence", detail: nil, file: "LICENSE-metal-shader-converter-headers.txt", folder: "d3d12"),
    ]

    /// Every licence text in the bundle's `legal/LICENSES` and `licenses` folders (the two overlap; each name is listed once).
    static var licenceTexts: [LegalDocument] {
        var seen = Set<String>()
        var out: [LegalDocument] = []
        for folder in ["legal/LICENSES", "licenses"] {
            let urls = (Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: folder) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
            for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = url.lastPathComponent
                let key = name.lowercased().replacingOccurrences(of: "mit-", with: "").replacingOccurrences(of: "-mit", with: "")
                guard seen.insert(key).inserted else { continue }
                out.append(LegalDocument(title: (name as NSString).deletingPathExtension, detail: nil, file: name, folder: folder))
            }
        }
        return out
    }
}
