// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import Foundation

/// Which stores the person hid from the Stores tab (the ones they do not use), kept as one comma-separated string so a view can follow it with @AppStorage.
/// Hiding changes only what is shown: the sign-in, the library and everything installed stay as they were, and a download that is running still shows in Downloads.
enum StoreVisibility {
    static let key = "f4.hiddenStores"

    static func hiddenIDs(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// `all` without the hidden ones, in the same order.
    static func visible<S: RawRepresentable>(_ all: [S], raw: String) -> [S] where S.RawValue == String {
        let hidden = hiddenIDs(raw)
        return all.filter { !hidden.contains($0.rawValue) }
    }

    /// The hidden ones among `all`, in the same order.
    static func hidden<S: RawRepresentable>(_ all: [S], raw: String) -> [S] where S.RawValue == String {
        let hidden = hiddenIDs(raw)
        return all.filter { hidden.contains($0.rawValue) }
    }

    /// The string with `id` hidden (or shown again). Ids that no longer exist are dropped, so the string never grows with stale names.
    static func setting(_ id: String, hidden: Bool, in raw: String, known: [String]) -> String {
        var set = hiddenIDs(raw).intersection(known)
        if hidden && known.contains(id) { set.insert(id) } else { set.remove(id) }
        return known.filter { set.contains($0) }.joined(separator: ",")
    }
}
