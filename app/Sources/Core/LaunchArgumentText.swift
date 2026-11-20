// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// A program's start options as typed on an iPhone or iPad. iOS's "smart punctuation" turns a straight quote into a curly one, two hyphens into a dash and three dots into one ellipsis
/// character, and a Windows program does not know any of those: `"C:\\Program Files (x86)\\..."` typed with curly quotes reaches it as `“C:\\Program` and `Files` and ..., and `--flag`
/// as `—flag`. This puts the plain characters back. Foundation only, so a host test can check it.
enum LaunchArgumentText {
    static func plain(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}", "\u{2033}": out.append("\"")
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": out.append("'")
            case "\u{2014}", "\u{2015}": out.append("--")
            case "\u{2013}", "\u{2212}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\u{00A0}", "\u{2007}", "\u{202F}": out.append(" ")
            default: out.append(character)
            }
        }
        return out
    }
}
